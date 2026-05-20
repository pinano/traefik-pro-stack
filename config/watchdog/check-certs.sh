#!/bin/sh

# Configuration
ACME_FILE="/acme.json"
WATCHDOG_CERT_DAYS_WARNING=${WATCHDOG_CERT_DAYS_WARNING:-10}
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "🔍 Starting certificate audit on $ACME_FILE..."

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d text="⚠️ *SSL ALERT* ⚠️%0A[\`${SERVER_DOMAIN}\`]%0A%0A${MSG}" \
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
    DOMAIN=$(echo "$CERT_B64" | base64 -d | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/^subject=CN=\([^,]*\).*$/\1/p')

    # Convert date to timestamp with date (GNU date from coreutils) which supports the -d flag.
    EXP_DATE=$(date -d "$END_DATE_STR" +%s 2>/dev/null)

    # Fallback for systems where date -d fails or formats differ
    if [ -z "$EXP_DATE" ]; then
        echo "⚠️ Warning: Could not parse date for $DOMAIN ($END_DATE_STR). Check 'date' command compatibility."
        continue
    fi

    DIFF=$((EXP_DATE - CURRENT_DATE))

    # Check if domain is expected
    IS_EXPECTED=false
    for ED in $EXPECTED_DOMAINS; do
        if [ "$DOMAIN" = "$ED" ]; then
            IS_EXPECTED=true
            break
        fi
    done

    if [ "$IS_EXPECTED" = "false" ]; then
        printf '%b\n' "${NC}[SKIP] $DOMAIN (not in expected list)${NC}"
        continue
    fi

    if [ $DIFF -lt $WARNING_SECONDS ]; then
        DAYS_LEFT=$((DIFF / 86400))
        printf '%b\n' "${RED}[DANGER] $DOMAIN expires in $DAYS_LEFT days ($END_DATE_STR)${NC}"

        # Send Telegram alert
        MESSAGE="The certificate for *${DOMAIN}* expires in *${DAYS_LEFT} days* (threshold: ${WATCHDOG_CERT_DAYS_WARNING} days).%0AAutomatic renewal has failed or is delayed.%0A👉 *Action Required:* Review Traefik renewal process immediately."
        send_telegram "$MESSAGE"
        ERRORS=$((ERRORS + 1))
    else
        printf '%b\n' "${GREEN}[OK] $DOMAIN ($((DIFF / 86400)) days left)${NC}"
    fi
    COUNT=$((COUNT + 1))
done < "$CERTS_FILE"

echo "✅ Audit finished. $COUNT certificates checked. $ERRORS alerts sent."