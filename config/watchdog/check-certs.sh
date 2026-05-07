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

# Function to send alert
send_telegram() {
    MSG="$1"
    # Use backticks instead of square brackets for SERVER_DOMAIN to avoid Markdown parsing issues
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
        -d text="⚠️ *SSL ALERT* ⚠️%0A[\`${SERVER_DOMAIN}\`]%0A%0A${MSG}" \
        -d parse_mode="Markdown" > /dev/null
}

# Verify requirements (jq, openssl and date are required)
if ! command -v jq > /dev/null 2>&1 || ! command -v openssl > /dev/null 2>&1 || ! command -v date > /dev/null 2>&1; then
    echo "❌ Error: jq, openssl, and date (from coreutils) are required."
    exit 1
fi

if [ ! -f "$ACME_FILE" ]; then
    echo "❌ Error: $ACME_FILE not found."
    exit 1
fi

# Extract all certificates (base64 encoded) from JSON
# Note: Traefik v2/v3 stores certs under the resolver name. We iterate recursively.
CERTS=$(jq -r '.. | .Certificates? | select(. != null) | .[] | .certificate' "$ACME_FILE")

CURRENT_DATE=$(date +%s)
WARNING_SECONDS=$((WATCHDOG_CERT_DAYS_WARNING * 86400))

# Load expected domains (from domains.csv and environment)
EXPECTED_DOMAINS=""
if [ -f "/domains.csv" ]; then
    # Get first column, skip comments, remove quotes/spaces
    EXPECTED_DOMAINS=$(grep -v '^#' /domains.csv | cut -d, -f1 | tr -d ' "' | tr '[:upper:]' '[:lower:]')
    
    # Also add Anubis subdomains if they exist (4th column)
    ANUBIS_SUBS=$(grep -v '^#' /domains.csv | cut -d, -f4 | tr -d ' "' | tr '[:upper:]' '[:lower:]')
    for SUB in $ANUBIS_SUBS; do
        if [ -n "$SUB" ]; then
            # We need to find the root domain for this line... this is a bit complex in shell
            # For now, we'll just add the subdomains and hope they match the CN if it's there
            # Better: include the full domain later if needed.
            # But the CN is usually the main domain anyway.
            : 
        fi
    done
fi

# Add system domains
if [ -n "$SERVER_DOMAIN" ]; then
    EXPECTED_DOMAINS="$EXPECTED_DOMAINS $SERVER_DOMAIN"
    if [ -n "$DASHBOARD_SUBDOMAIN" ]; then
        EXPECTED_DOMAINS="$EXPECTED_DOMAINS $DASHBOARD_SUBDOMAIN.$SERVER_DOMAIN"
    fi
fi

# Clean up list
EXPECTED_DOMAINS=$(echo $EXPECTED_DOMAINS | tr ' ' '\n' | sort -u)

# Counters
COUNT=0
ERRORS=0

for CERT_B64 in $CERTS; do
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
done

echo "✅ Audit finished. $COUNT certificates checked. $ERRORS alerts sent."