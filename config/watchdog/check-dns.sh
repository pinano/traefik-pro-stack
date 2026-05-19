#!/bin/sh

# DNS Check Script - Verifies all domains in domains.csv point to the host IP
# Sends Telegram alert if any domain has mismatched DNS
# Includes double-check mechanism to reduce false positives

# Configuration
DOMAINS_FILE="/domains.csv"
WATCHDOG_DNS_CHECK_INTERVAL=${WATCHDOG_DNS_CHECK_INTERVAL:-21600}
DNS_RECHECK_DELAY=${DNS_RECHECK_DELAY:-10}  # Seconds to wait before double-checking failed domains
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"
TRAEFIK_LISTEN_IP="${TRAEFIK_LISTEN_IP}"

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "🔍 Starting DNS verification check..."

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d text="🌐 *DNS ALERT* 🌐%0A[\`${SERVER_DOMAIN}\`]%0A%0A${MSG}" \
            -d parse_mode="Markdown" > /dev/null
    }
fi

# Function to check a single domain's DNS
# Returns: 0 if OK, 1 if no A record, 2 if IP mismatch
# Sets RESOLVED_IP variable with the resolved IP
check_domain_dns() {
    local domain="$1"
    RESOLVED_IP=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    if [ -z "$RESOLVED_IP" ]; then
        return 1  # No A record
    elif [ "$RESOLVED_IP" != "$HOST_IP" ]; then
        return 2  # IP mismatch
    else
        return 0  # OK
    fi
}

# Verify requirements
if ! command -v dig > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
    echo "❌ Error: dig (bind-tools) and curl are required."
    exit 1
fi

if [ ! -f "$DOMAINS_FILE" ]; then
    echo "❌ Error: $DOMAINS_FILE not found."
    exit 1
fi

# Determine the expected IP
# If TRAEFIK_LISTEN_IP is empty or 0.0.0.0, auto-detect public IP
# Otherwise, use the configured IP
if [ -z "$TRAEFIK_LISTEN_IP" ] || [ "$TRAEFIK_LISTEN_IP" = "0.0.0.0" ]; then
    echo "📡 Auto-detecting public IP..."
    HOST_IP=$(curl -s --max-time 10 ifconfig.me)
    if [ -z "$HOST_IP" ]; then
        echo "⚠️ Warning: Could not detect public IP. Trying alternative..."
        HOST_IP=$(curl -s --max-time 10 icanhazip.com)
    fi
    if [ -z "$HOST_IP" ]; then
        echo "❌ Error: Could not detect public IP."
        send_telegram "Could not detect public IP for DNS verification."
        exit 1
    fi
    # Validate that the detected value is a proper IPv4 address.
    # A CDN outage or captcha page could return HTML instead of an IP,
    # causing false-positive DNS alerts for every single domain.
    if ! echo "$HOST_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "❌ Error: Detected value '$HOST_IP' is not a valid IPv4 address. Aborting."
        send_telegram "Could not detect a valid public IPv4 address for DNS verification (got unexpected response from IP detection service)."
        exit 1
    fi
    echo "🌐 Detected public IP: $HOST_IP"
else
    HOST_IP="$TRAEFIK_LISTEN_IP"
    echo "🌐 Using configured IP: $HOST_IP"
fi

# Counters and lists
TOTAL=0
FAILED_DOMAINS=""  # Domains that failed initial check (for double-check)
FAILED_REASONS=""  # Parallel list of failure reasons

# First pass: Read domains from CSV and check each one
echo ""
echo "📋 First pass: Initial DNS check..."
while IFS=, read -r domain rest || [ -n "$domain" ]; do
    # Skip empty lines and comments
    domain=$(echo "$domain" | xargs)
    case "$domain" in
        ""|"#"*) continue ;;
    esac

    TOTAL=$((TOTAL + 1))

    check_domain_dns "$domain"
    result=$?

    if [ $result -eq 1 ]; then
        printf '%b\n' "${YELLOW}[WARN] $domain - No A record found (will recheck)${NC}"
        FAILED_DOMAINS="${FAILED_DOMAINS}${domain}|"
        FAILED_REASONS="${FAILED_REASONS}no_record|"
    elif [ $result -eq 2 ]; then
        printf '%b\n' "${YELLOW}[WARN] $domain -> $RESOLVED_IP (expected: $HOST_IP) (will recheck)${NC}"
        FAILED_DOMAINS="${FAILED_DOMAINS}${domain}|"
        FAILED_REASONS="${FAILED_REASONS}mismatch:${RESOLVED_IP}|"
    else
        printf '%b\n' "${GREEN}[OK] $domain -> $RESOLVED_IP${NC}"
    fi
done < "$DOMAINS_FILE"

# Second pass: Double-check failed domains after a delay
ERRORS=0
MISMATCHED_DOMAINS=""

if [ -n "$FAILED_DOMAINS" ]; then
    echo ""
    printf '%b\n' "${CYAN}⏳ Waiting ${DNS_RECHECK_DELAY} seconds before double-checking failed domains...${NC}"
    sleep "$DNS_RECHECK_DELAY"

    # Unique temp file for collecting errors from the subshell
    DNS_ERRORS_FILE=$(mktemp /tmp/dns_errors_XXXXXX.txt)
    trap 'rm -f "$DNS_ERRORS_FILE"' EXIT INT TERM

    echo ""
    echo "📋 Second pass: Double-checking failed domains..."

    # Parse the failed domains list
    echo "$FAILED_DOMAINS" | tr '|' '\n' | while read -r domain; do
        [ -z "$domain" ] && continue

        check_domain_dns "$domain"
        result=$?

        if [ $result -eq 1 ]; then
            printf '%b\n' "${RED}[FAIL] $domain - No A record found (confirmed)${NC}"
            # Write to temp file since we're in a subshell
            echo "• *${domain}*: No A record found%0A" >> "$DNS_ERRORS_FILE"
        elif [ $result -eq 2 ]; then
            printf '%b\n' "${RED}[FAIL] $domain -> $RESOLVED_IP (expected: $HOST_IP) (confirmed)${NC}"
            echo "• *${domain}*: Points to \`${RESOLVED_IP}\` instead of \`${HOST_IP}\`%0A" >> "$DNS_ERRORS_FILE"
        else
            printf '%b\n' "${GREEN}[OK] $domain -> $RESOLVED_IP (recovered)${NC}"
        fi
    done

    # Read errors from unique temp file
    if [ -f "$DNS_ERRORS_FILE" ]; then
        MISMATCHED_DOMAINS=$(cat "$DNS_ERRORS_FILE")
        ERRORS=$(wc -l < "$DNS_ERRORS_FILE" | tr -d ' ')
        rm -f "$DNS_ERRORS_FILE"
    fi
fi

# Send alert if there are confirmed mismatches
if [ $ERRORS -gt 0 ]; then
    MESSAGE="Found *${ERRORS}* domain(s) with DNS issues (confirmed after double-check):%0A%0A${MISMATCHED_DOMAINS}%0A👉 *Action Required:* Update DNS records to point to \`${HOST_IP}\`"
    send_telegram "$MESSAGE"
    echo ""
    printf '%b\n' "${RED}⚠️ DNS check completed with $ERRORS confirmed error(s). Alert sent.${NC}"
else
    echo ""
    printf '%b\n' "${GREEN}✅ DNS check completed. All $TOTAL domains point correctly to $HOST_IP${NC}"
fi

echo "📊 Summary: $TOTAL domains checked, $ERRORS with confirmed issues."
