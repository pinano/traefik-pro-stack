#!/bin/sh

# Configuration
ACME_FILE="/acme.json"
WATCHDOG_CERT_DAYS_WARNING=${WATCHDOG_CERT_DAYS_WARNING:-10}
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"

# Guard: Skip check in local dev environment
if [ "${TRAEFIK_ACME_ENV_TYPE:-}" = "local" ]; then
    echo "🏠 Local development environment detected (TRAEFIK_ACME_ENV_TYPE=local)."
    echo "   Bypassing certificate checks (using local trusted certificates)."
    exit 0
fi

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'


echo "🔍 Starting certificate audit on $ACME_FILE..."

# Add a startup delay to avoid race conditions with other services booting
if [ ! -f "/tmp/certs_check_settled" ]; then
    echo "⏳ Sleeping 5s to allow the stack to settle..."
    sleep 5
    touch "/tmp/certs_check_settled"
fi

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d text="⚠️ *WATCHDOG - SSL Alert*%0A🌐 *${SERVER_DOMAIN}*%0A%0A${MSG}" \
            -d parse_mode="Markdown" > /dev/null
    }
fi

# Verify requirements (jq, openssl and date are required)
if ! command -v jq > /dev/null 2>&1 || ! command -v openssl > /dev/null 2>&1 || ! command -v date > /dev/null 2>&1; then
    echo "❌ Error: jq, openssl, and date (from coreutils) are required."
    exit 1
fi

if [ ! -f "$ACME_FILE" ]; then
    echo "❌ Error: $ACME_FILE not found."
    send_telegram "ACME certificate file \`$ACME_FILE\` not found!%0A👉 *Action Required:* Verify that Traefik is running and the acme.json volume is correctly mapped."
    exit 1
fi

if ! jq empty "$ACME_FILE" 2>/dev/null; then
    echo "❌ Error: $ACME_FILE contains invalid JSON."
    send_telegram "ACME certificate file \`$ACME_FILE\` contains invalid JSON!%0A👉 *Action Required:* Inspect the acme.json file to locate and repair corrupted data."
    exit 1
fi


# Extract all certificates (base64 encoded) from JSON into a temp file.
# Using a temp file instead of a variable avoids two problems:
#   1. Word-splitting: 'for X in $VAR' breaks multi-line base64 values on whitespace.
#   2. Subshell scope: piping into 'while' would prevent COUNT/ERRORS from accumulating.
CERTS_FILE=$(mktemp /tmp/certs_XXXXXX)
trap 'rm -f "$CERTS_FILE"' EXIT INT TERM

jq -r '.. | .Certificates? | select(. != null) | .[] | .certificate' "$ACME_FILE" > "$CERTS_FILE"

CURRENT_DATE=$(date +%s)
WARNING_SECONDS=$((WATCHDOG_CERT_DAYS_WARNING * 86400))

# Helper to extract root domain (e.g. sub.example.com -> example.com)
# Handles common double TLDs (co.uk, com.es, com.br, etc.)
get_root_domain() {
    local input_domain="$1"
    # Lowercase the domain
    input_domain=$(echo "$input_domain" | tr '[:upper:]' '[:lower:]')
    
    # Check if domain has at least 3 parts (e.g. a.b.c)
    local dots_count=$(echo "$input_domain" | tr -cd '.' | wc -c)
    if [ "$dots_count" -lt 2 ]; then
        echo "$input_domain"
        return
    fi
    
    # Check for common two-part TLDs (e.g. .co.uk, .com.es, etc.)
    if echo "$input_domain" | grep -qE '\.(co|com|org|net|edu|gov|mil|nom|biz|info)\.[a-z]{2,3}$'; then
        if [ "$dots_count" -ge 3 ]; then
            echo "$input_domain" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
        else
            echo "$input_domain"
        fi
    else
        echo "$input_domain" | awk -F. '{print $(NF-1)"."$NF}'
    fi
}

# Helper to check if an expected domain matches a certificate domain (including wildcard support)
match_wildcard() {
    local expected="$1"
    local cert_dom="$2"
    
    if [ "$expected" = "$cert_dom" ]; then
        return 0
    fi
    
    if echo "$cert_dom" | grep -q '^\*\.'; then
        local suffix=$(echo "$cert_dom" | cut -c 3-)
        local without_suffix=${expected%.$suffix}
        if [ "$without_suffix" != "$expected" ] && [ -n "$without_suffix" ]; then
            if ! echo "$without_suffix" | grep -q '\.'; then
                return 0
            fi
        fi
    fi
    
    return 1
}


# Load expected domains (from domains.csv and environment)
EXPECTED_DOMAINS=""
if [ -f "/domains.csv" ]; then
    while IFS=, read -r domain redir svc anubis_sub rest || [ -n "$domain" ]; do
        # Strip spaces and quotes
        domain=$(echo "$domain" | tr -d ' "')
        # Skip comments and empty lines
        case "$domain" in
            ""|"#"*) continue ;;
        esac
        domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
        EXPECTED_DOMAINS="$EXPECTED_DOMAINS $domain"
        
        # Parse anubis subdomain if present
        anubis_sub=$(echo "$anubis_sub" | tr -d ' "')
        if [ -n "$anubis_sub" ]; then
            root_dom=$(get_root_domain "$domain")
            EXPECTED_DOMAINS="$EXPECTED_DOMAINS ${anubis_sub}.${root_dom}"
        fi
    done < "/domains.csv"
fi

# Add system domains
if [ -n "$SERVER_DOMAIN" ]; then
    if [ -n "$DASHBOARD_SUBDOMAIN" ]; then
        EXPECTED_DOMAINS="$EXPECTED_DOMAINS $DASHBOARD_SUBDOMAIN.$SERVER_DOMAIN"
    else
        EXPECTED_DOMAINS="$EXPECTED_DOMAINS $SERVER_DOMAIN"
    fi
fi

# Clean up list
EXPECTED_DOMAINS=$(echo $EXPECTED_DOMAINS | tr ' ' '\n' | sort -u)

# Counters
COUNT=0
ERRORS=0

# Keep track of domains found in certificates
FOUND_DOMAINS=""

while IFS= read -r CERT_B64; do
    [ -z "$CERT_B64" ] && continue

    # Decode and read expiration date
    # Force the ISO 8601 format with '-dateopt iso_8601' to avoid parsing problems in Alpine
    CERT_TEXT=$(echo "$CERT_B64" | base64 -d | openssl x509 -noout -enddate -subject -dateopt iso_8601 2>/dev/null)

    if [ -z "$CERT_TEXT" ]; then
        continue
    fi

    # Clean whitespaces with xargs after trimming the openssl string
    END_DATE_STR=$(echo "$CERT_TEXT" | grep "notAfter=" | cut -d= -f2 | xargs)
    CN=$(echo "$CERT_B64" | base64 -d | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/^subject=CN=\([^,]*\).*$/\1/p')
    SANS=$(echo "$CERT_B64" | base64 -d | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | cut -d: -f2)

    # Combine CN and SANs to get all domains in this cert
    DOMAINS_IN_CERT=$(printf "%s\n%s" "$CN" "$SANS" | grep -v '^$' | sort -u | xargs)

    # Convert date to timestamp with date (GNU date from coreutils) which supports the -d flag.
    EXP_DATE=$(date -d "$END_DATE_STR" +%s 2>/dev/null)

    # Fallback for systems where date -d fails or formats differ
    if [ -z "$EXP_DATE" ]; then
        echo "⚠️ Warning: Could not parse date for $CN ($END_DATE_STR). Check 'date' command compatibility."
        continue
    fi

    DIFF=$((EXP_DATE - CURRENT_DATE))

    # Check if this certificate covers any of our expected domains
    IS_EXPECTED=false
    COVERED_EXPECTED_DOMAINS=""
    for ED in $EXPECTED_DOMAINS; do
        for DIC in $DOMAINS_IN_CERT; do
            if match_wildcard "$ED" "$DIC"; then
                IS_EXPECTED=true
                FOUND_DOMAINS="$FOUND_DOMAINS $ED"
                COVERED_EXPECTED_DOMAINS="$COVERED_EXPECTED_DOMAINS $ED"
                break # Move to next expected domain
            fi
        done
    done

    # If it covers none of our expected domains, skip it
    if [ "$IS_EXPECTED" = "false" ]; then
        printf '%b\n' "${NC}[SKIP] $CN (does not cover any expected domains)${NC}"
        continue
    fi

    DISPLAY_DOMAINS=$(echo "$COVERED_EXPECTED_DOMAINS" | xargs | tr ' ' ',')

    if [ $DIFF -lt $WARNING_SECONDS ]; then
        DAYS_LEFT=$((DIFF / 86400))
        printf '%b\n' "${RED}[DANGER] Cert covering [$DISPLAY_DOMAINS] expires in $DAYS_LEFT days ($END_DATE_STR)${NC}"

        # Send Telegram alert
        MESSAGE="The certificate covering *${DISPLAY_DOMAINS}* expires in *${DAYS_LEFT} days* (threshold: ${WATCHDOG_CERT_DAYS_WARNING} days).%0AAutomatic renewal has failed or is delayed.%0A👉 *Action Required:* Review Traefik renewal process immediately."
        send_telegram "$MESSAGE"
        ERRORS=$((ERRORS + 1))
    else
        printf '%b\n' "${GREEN}[OK] Cert covering [$DISPLAY_DOMAINS] ($((DIFF / 86400)) days left)${NC}"
    fi
    COUNT=$((COUNT + 1))
done < "$CERTS_FILE"

# Clean up lists of domains
FOUND_DOMAINS=$(echo $FOUND_DOMAINS | tr ' ' '\n' | sort -u)

# Find missing expected domains
MISSING_DOMAINS=""
MISSING_COUNT=0
for ED in $EXPECTED_DOMAINS; do
    FOUND=false
    for FD in $FOUND_DOMAINS; do
        if [ "$ED" = "$FD" ]; then
            FOUND=true
            break
        fi
    done
    if [ "$FOUND" = "false" ]; then
        MISSING_DOMAINS="${MISSING_DOMAINS}• *${ED}*%0A"
        MISSING_COUNT=$((MISSING_COUNT + 1))
        printf '%b\n' "${RED}[MISSING] Expected domain $ED has no certificate in acme.json!${NC}"
    fi
done

if [ $MISSING_COUNT -gt 0 ]; then
    MESSAGE="Found *${MISSING_COUNT}* expected domain(s) with *no SSL certificates* in acme.json:%0A%0A${MISSING_DOMAINS}%0ATraefik may have failed to resolve or obtain certificates for them.%0A👉 *Action Required:* Check Traefik logs to debug certificate generation."
    send_telegram "$MESSAGE"
    ERRORS=$((ERRORS + MISSING_COUNT))
fi

echo "✅ Audit finished. $COUNT certificates checked. $MISSING_COUNT missing domains. $ERRORS alerts sent."