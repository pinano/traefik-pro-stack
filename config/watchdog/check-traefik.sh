#!/bin/sh

# Traefik Health & Configuration Check Script
# Monitors Traefik dynamic configuration errors (routers, services, middlewares)
# via the internal Traefik API.
# Sends Telegram alerts on errors.

# Configuration
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"
SERVER_DOMAIN="${SERVER_DOMAIN}"
WATCHDOG_TRAEFIK_CHECK_INTERVAL=${WATCHDOG_TRAEFIK_CHECK_INTERVAL:-300}

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "🔍 Starting Traefik configuration and health check..."

# Add a startup delay to avoid race conditions with other services booting
if [ ! -f "/tmp/traefik_check_settled" ]; then
    echo "⏳ Sleeping 45s to allow the stack and Traefik to settle..."
    sleep 45
    touch "/tmp/traefik_check_settled"
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
            -d text="🔀 <b>WATCHDOG - Traefik Alert</b>%0A🌐 <b>${SERVER_DOMAIN}</b>%0A%0A${MSG}" \
            -d parse_mode="HTML" > /dev/null
    }
fi

# Fetch rawdata from Traefik API (internal port 8080) with retries
# During startup, Traefik might take a short while to initialize the API provider.
TRAEFIK_API_URL="http://traefik:8080/api/rawdata"
MAX_RETRIES=6
RETRY_COUNT=0
RAWDATA=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RAWDATA=$(curl -s --max-time 10 "$TRAEFIK_API_URL")
    CURL_STATUS=$?
    
    # Check if curl succeeded and the response is valid JSON
    if [ $CURL_STATUS -eq 0 ] && [ -n "$RAWDATA" ] && echo "$RAWDATA" | jq empty 2>/dev/null; then
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        printf '%b\n' "${YELLOW}⚠️ Warning: Traefik API not ready or invalid response (Attempt $RETRY_COUNT/$MAX_RETRIES). Retrying in 10s...${NC}"
        sleep 10
    fi
done

if [ -z "$RAWDATA" ] || ! echo "$RAWDATA" | jq empty 2>/dev/null; then
    printf '%b\n' "${RED}❌ Error: Could not retrieve valid configuration from Traefik API after $MAX_RETRIES attempts.${NC}"
    send_telegram "Could not retrieve valid configuration from Traefik API!%0A👉 <b>Action Required:</b> Check if Traefik is running and has the API enabled on port 8080."
    exit 1
fi

# Parse errors (HTTP & TCP/UDP routers, services, middlewares)
ERRORS=$(echo "$RAWDATA" | jq -r '
  def format_err: if type=="array" then join("; ") else . end | gsub("[\"\\[\\]]"; "");
  (
    [(.routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>Router</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [(.services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>Service</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [(.middlewares // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>Middleware</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [((.tcp // {}).routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>TCP Router</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [((.tcp // {}).services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>TCP Service</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [((.tcp // {}).middlewares // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>TCP Middleware</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [((.udp // {}).routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>UDP Router</b> \(.key): \(.value.error | format_err // "Configuration error")"] +
    [((.udp // {}).services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "🔸 <b>UDP Service</b> \(.key): \(.value.error | format_err // "Configuration error")"]
  )[]
' 2>/dev/null)

if [ -n "$ERRORS" ]; then
    ERROR_COUNT=$(echo "$ERRORS" | grep -c .)
else
    ERROR_COUNT=0
fi

# If error count has any characters (not empty) and is greater than 0
if [ "$ERROR_COUNT" -gt 0 ] && [ -n "$ERRORS" ]; then
    printf '%b\n' "${RED}❌ Found $ERROR_COUNT misconfigured component(s) in Traefik!${NC}"
    echo "$ERRORS"
    
    # Escape HTML special characters (&, <, >) to prevent broken Telegram HTML parsing.
    SAFE_ERRORS=$(echo "$ERRORS" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    
    # Convert newline characters to %0A for URL encoding.
    ENCODED_ERRORS=$(echo "$SAFE_ERRORS" | awk '{printf "%s%%0A", $0}')
    
    send_telegram "Traefik check detected <b>${ERROR_COUNT}</b> component(s) in error state:%0A%0A${ENCODED_ERRORS}%0A👉 <b>Action Required:</b> Inspect the Traefik dashboard or check container logs."
    exit 1
else
    printf '%b\n' "${GREEN}✅ Traefik check completed successfully. All components are healthy.${NC}"
fi
