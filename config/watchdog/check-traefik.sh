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

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d text="🐕 *WATCHDOG - 🔀 Traefik Alert*%0A[\`${SERVER_DOMAIN}\`]%0A%0A${MSG}" \
            -d parse_mode="Markdown" > /dev/null
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
    send_telegram "Could not retrieve valid configuration from Traefik API!%0A👉 *Action Required:* Check if Traefik is running and has the API enabled on port 8080."
    exit 1
fi

# Parse errors (HTTP & TCP/UDP routers, services, middlewares)
ERRORS=$(echo "$RAWDATA" | jq -r '
  (
    [(.routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• Router \(.key): \(.value.error // "Configuration error")"] +
    [(.services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• Service \(.key): \(.value.error // "Configuration error")"] +
    [(.middlewares // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• Middleware \(.key): \(.value.error // "Configuration error")"] +
    [((.tcp // {}).routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• TCP Router \(.key): \(.value.error // "Configuration error")"] +
    [((.tcp // {}).services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• TCP Service \(.key): \(.value.error // "Configuration error")"] +
    [((.tcp // {}).middlewares // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• TCP Middleware \(.key): \(.value.error // "Configuration error")"] +
    [((.udp // {}).routers // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• UDP Router \(.key): \(.value.error // "Configuration error")"] +
    [((.udp // {}).services // {}) | to_entries[] | select(.value.status == "error" or .value.error != null) | "• UDP Service \(.key): \(.value.error // "Configuration error")"]
  )[]
' 2>/dev/null)

ERROR_COUNT=$(echo "$ERRORS" | grep -c . || echo "0")

# If error count has any characters (not empty) and is greater than 0
if [ "$ERROR_COUNT" -gt 0 ] && [ -n "$ERRORS" ]; then
    printf '%b\n' "${RED}❌ Found $ERROR_COUNT misconfigured component(s) in Traefik!${NC}"
    echo "$ERRORS"
    
    # Replace backticks with single quotes to avoid escaping issues in code blocks
    SAFE_ERRORS=$(echo "$ERRORS" | tr '`' "'")
    
    # Format message for Telegram, escaping special Markdown characters outside the code block
    # and wrapping the error list in a preformatted code block.
    # Convert newline characters to %0A for URL encoding.
    ENCODED_ERRORS=$(echo "$SAFE_ERRORS" | awk '{printf "%s%%0A", $0}')
    
    send_telegram "Traefik check detected *${ERROR_COUNT}* component(s) in error state:%0A%0A\`\`\`%0A${ENCODED_ERRORS}\`\`\`%0A👉 *Action Required:* Inspect the Traefik dashboard or check container logs."
    exit 1
else
    printf '%b\n' "${GREEN}✅ Traefik check completed successfully. All components are healthy.${NC}"
fi
