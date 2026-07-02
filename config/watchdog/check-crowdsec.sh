#!/bin/sh

# CrowdSec Health Check Script - Monitors CrowdSec status via Docker
# Sends Telegram alert if CrowdSec or bouncers are having issues

# Configuration
CROWDSEC_CONTAINER="${CROWDSEC_CONTAINER:-crowdsec}"
CROWDSEC_CHECK_INTERVAL=${WATCHDOG_CROWDSEC_CHECK_INTERVAL:-3600}
TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}"
TELEGRAM_RECIPIENT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}"
PROJECT_NAME="${PROJECT_NAME:-stack}"

# Colors for local logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Temp file paths declared here so the cleanup trap can always reference them,
# even if the script exits before they are created.
GROUP_DIR=""
BOUNCER_LIST_FILE=""

cleanup() {
    rm -rf "$GROUP_DIR"
    rm -f  "$BOUNCER_LIST_FILE"
}
trap cleanup EXIT INT TERM

echo "🛡️ Starting CrowdSec health check..."

# Add a startup delay to avoid race conditions with other services booting
if [ ! -f "/tmp/crowdsec_check_settled" ]; then
    echo "⏳ Sleeping 30s to allow the stack and docker daemon to settle..."
    sleep 30
    touch "/tmp/crowdsec_check_settled"
fi

# Guard: if Telegram credentials are not configured, degrade gracefully
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_RECIPIENT_ID" ]; then
    echo "⚠️  Warning: Telegram credentials not configured — alerts will be logged locally only."
    send_telegram() { echo "[TELEGRAM DISABLED] $1"; }
else
    send_telegram() {
        MSG="$1"
        TEXT=$(printf '%s' "🛡️ <b>WATCHDOG - CrowdSec Alert</b>
🌐 <b>${SERVER_DOMAIN}</b>

${MSG}" | awk '{gsub(/%0A/, "\n"); print}')
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_RECIPIENT_ID}" \
            -d parse_mode="HTML" \
            --data-urlencode "text=${TEXT}" > /dev/null
    }
fi

# Verify docker socket is available
if [ ! -S /var/run/docker.sock ]; then
    printf '%b\n' "${RED}❌ Error: Docker socket not available.${NC}"
    exit 1
fi

# Check if CrowdSec container is running (with retries for robustness)
MAX_RETRIES=5
RETRY_COUNT=0
CONTAINER_STATUS=""
REAL_CONTAINER_ID=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # 1. Try finding by project + service labels (standard compose)
    if [ -n "$PROJECT_NAME" ]; then
        REAL_CONTAINER_ID=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=crowdsec" 2>/dev/null | head -n 1)
    fi

    # 2. Try finding by service label alone (handles project name mismatches)
    if [ -z "$REAL_CONTAINER_ID" ]; then
        REAL_CONTAINER_ID=$(docker ps -aq --filter "label=com.docker.compose.service=crowdsec" 2>/dev/null | head -n 1)
    fi

    # 3. Try finding by exact name match (handles custom non-compose setups)
    if [ -z "$REAL_CONTAINER_ID" ]; then
        REAL_CONTAINER_ID=$(docker ps -aq --filter "name=^/${CROWDSEC_CONTAINER}$" 2>/dev/null | head -n 1)
    fi

    # 4. Fallback to name substring match, excluding crowdsec-web-ui to avoid false matching
    if [ -z "$REAL_CONTAINER_ID" ]; then
        REAL_CONTAINER_ID=$(docker ps -a --filter "name=$CROWDSEC_CONTAINER" --format "{{.ID}}|{{.Names}}" 2>/dev/null | grep -v "web-ui" | head -n 1 | cut -d'|' -f1)
    fi

    # Only break the loop if we found the ID AND successfully queried its status
    if [ -n "$REAL_CONTAINER_ID" ]; then
        CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$REAL_CONTAINER_ID" 2>/dev/null)
        if [ -n "$CONTAINER_STATUS" ]; then
            break
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        printf '%b\n' "${YELLOW}⚠️ Warning: CrowdSec container not found or Docker API error (Attempt $RETRY_COUNT/$MAX_RETRIES). Retrying in 5s...${NC}"
        sleep 5
    fi
done

if [ -z "$REAL_CONTAINER_ID" ] || [ -z "$CONTAINER_STATUS" ]; then
    printf '%b\n' "${RED}❌ CrowdSec container not found or Docker API error after $MAX_RETRIES attempts!${NC}"
    send_telegram "CrowdSec container not found or Docker API error!%0A👉 <b>Action Required:</b> Check if the container exists and is properly configured. If necessary, you can try restarting it (e.g., <code>make restart crowdsec</code>)."
    exit 1
fi

# Update variable to use the ID for subsequent commands
CROWDSEC_CONTAINER="$REAL_CONTAINER_ID"

if [ "$CONTAINER_STATUS" != "running" ]; then
    printf '%b\n' "${RED}❌ CrowdSec container is not running (status: $CONTAINER_STATUS)${NC}"
    send_telegram "CrowdSec container is <b>not running</b>!%0ACurrent status: <code>${CONTAINER_STATUS}</code>%0A👉 <b>Action Required:</b> Restart the CrowdSec container (e.g., <code>make restart crowdsec</code>)."
    exit 1
fi

printf '%b\n' "${GREEN}✅ CrowdSec container is running${NC}"

# Check LAPI status
LAPI_STATUS=$(docker exec "$CROWDSEC_CONTAINER" cscli lapi status 2>&1)
LAPI_EXIT_CODE=$?

if [ $LAPI_EXIT_CODE -ne 0 ]; then
    printf '%b\n' "${RED}❌ CrowdSec LAPI is not healthy!${NC}"
    echo "$LAPI_STATUS"
    # Strip HTML special characters from LAPI output before embedding in the alert
    # to prevent broken HTML formatting in Telegram.
    LAPI_SAFE=$(echo "$LAPI_STATUS" | head -5 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    send_telegram "CrowdSec LAPI is <b>not healthy</b>!%0A%0AError output:%0A<pre>${LAPI_SAFE}</pre>%0A👉 <b>Action Required:</b> Check CrowdSec logs, and if necessary, restart the container (e.g., <code>make restart crowdsec</code>)."
    exit 1
fi

printf '%b\n' "${GREEN}✅ CrowdSec LAPI is healthy${NC}"

# Check AppSec status (if enabled)
if [ "${CROWDSEC_APPSEC_ENABLE:-true}" != "false" ]; then
    APPSEC_STATUS=$(docker exec "$CROWDSEC_CONTAINER" sh -c 'wget -qO- http://localhost:7422/ 2>&1' || echo "failed")
    if ! echo "$APPSEC_STATUS" | grep -q "401 Unauthorized"; then
        printf '%b\n' "${RED}❌ CrowdSec AppSec WAF is not healthy / not listening on port 7422!${NC}"
        send_telegram "CrowdSec AppSec WAF is <b>not healthy</b>!%0A👉 <b>Action Required:</b> Check CrowdSec logs. Verify if the AppSec block is in <code>acquis.yaml</code> and rules are loaded."
        exit 1
    fi
    printf '%b\n' "${GREEN}✅ CrowdSec AppSec WAF is healthy${NC}"
fi

# Check registered bouncers
BOUNCERS=$(docker exec "$CROWDSEC_CONTAINER" cscli bouncers list -o json 2>/dev/null)
BOUNCER_COUNT=$(echo "$BOUNCERS" | jq 'length' 2>/dev/null || echo "0")

if [ -n "$CROWDSEC_LAPI_KEY" ]; then
    # Test API key validity
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Api-Key: $CROWDSEC_LAPI_KEY" http://crowdsec:8080/v1/decisions/stream?startup=true)
    
    # Check if traefik-bouncer is registered
    HAS_TRAEFIK_BOUNCER=$(echo "$BOUNCERS" | jq -r '.[] | select(.name == "traefik-bouncer") | .name' 2>/dev/null)
    
    if [ "$HTTP_CODE" = "403" ] || [ -z "$HAS_TRAEFIK_BOUNCER" ]; then
        printf '%b\n' "${YELLOW}🔧 Self-healing: traefik-bouncer is missing or unauthorized (LAPI returned HTTP $HTTP_CODE). Re-registering...${NC}"
        
        # Delete the bouncer if it exists to avoid duplicate/mismatched registration
        docker exec "$CROWDSEC_CONTAINER" cscli bouncers delete traefik-bouncer >/dev/null 2>&1 || true
        
        # Register the bouncer securely
        ADD_OUTPUT=$(echo "${CROWDSEC_LAPI_KEY}" | docker exec -i "$CROWDSEC_CONTAINER" sh -c 'read -r KEY && cscli bouncers add traefik-bouncer --key "$KEY"' 2>&1)
        ADD_EXIT=$?
        
        if [ $ADD_EXIT -eq 0 ]; then
            printf '%b\n' "${GREEN}✅ Self-healing succeeded: traefik-bouncer registered successfully.${NC}"
            # Refresh bouncer list and count
            BOUNCERS=$(docker exec "$CROWDSEC_CONTAINER" cscli bouncers list -o json 2>/dev/null)
            BOUNCER_COUNT=$(echo "$BOUNCERS" | jq 'length' 2>/dev/null || echo "0")
            send_telegram "Self-healing triggered: traefik-bouncer was missing or unauthorized (LAPI returned 403) and has been successfully re-registered."
        else
            printf '%b\n' "${RED}❌ Self-healing failed: $ADD_OUTPUT${NC}"
            send_telegram "Self-healing failed: traefik-bouncer is missing or unauthorized, and re-registration failed. Error: $ADD_OUTPUT"
        fi
    fi
fi

if [ "$BOUNCER_COUNT" = "0" ] || [ -z "$BOUNCER_COUNT" ]; then
    printf '%b\n' "${YELLOW}⚠️ No bouncers registered with CrowdSec${NC}"
    send_telegram "No bouncers are registered with CrowdSec!%0A%0A👉 <b>Action Required:</b> Register the Traefik bouncer to enable protection. If they should be registered, try restarting the container (e.g., <code>make restart crowdsec</code>)."
else
    printf '%b\n' "${GREEN}✅ $BOUNCER_COUNT bouncer(s) registered${NC}"

    CURRENT_TIME=$(date +%s)
    STALE_THRESHOLD=600    # 10 minutes (to avoid false positives with Traefik plugins)
    PRUNE_THRESHOLD=172800 # 48 hours (to cleanup very old stale entries)

    # Use a temp directory to group bouncers
    GROUP_DIR=$(mktemp -d /tmp/crowdsec_bouncers_XXXXXX)

    # Process bouncers and group them by base name
    # NOTE: We read into a temp file first to avoid subshell variable scope issues
    BOUNCER_LIST_FILE=$(mktemp /tmp/crowdsec_list_XXXXXX)
    echo "$BOUNCERS" | jq -r '.[] | "\(.name)|\(.last_pull)|\(.created_at)"' 2>/dev/null > "$BOUNCER_LIST_FILE"

    while IFS='|' read -r full_name last_pull created_at; do
        # Extract base name (e.g., traefik-bouncer from traefik-bouncer@172.19.0.6)
        base_name=$(echo "$full_name" | cut -d'@' -f1)

        IS_STALE=1
        IS_REALLY_OLD=0
        LAST_PULL_TS=""

        if [ -n "$last_pull" ] && [ "$last_pull" != "null" ]; then
            # Handle possible multiple instances by taking the first one if jq returned multiple
            last_pull_actual=$(echo "$last_pull" | head -n 1)
            LAST_PULL_TS=$(date -d "$last_pull_actual" +%s 2>/dev/null)

            # Only proceed if we got a valid timestamp
            if [ -n "$LAST_PULL_TS" ] && echo "$LAST_PULL_TS" | grep -q '^[0-9]\+$'; then
                DIFF=$((CURRENT_TIME - LAST_PULL_TS))
                [ $DIFF -le $STALE_THRESHOLD ] && IS_STALE=0
                [ $DIFF -gt $PRUNE_THRESHOLD ] && IS_REALLY_OLD=1
            fi
        else
            # last_pull is null: bouncer has never pulled yet.
            # Give it a grace period equal to STALE_THRESHOLD based on its creation time.
            # This avoids false positives on stack startup (Traefik takes ~1-2 min to connect).
            if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
                CREATED_TS=$(date -d "$created_at" +%s 2>/dev/null)
                if [ -n "$CREATED_TS" ] && echo "$CREATED_TS" | grep -q '^[0-9]\+$'; then
                    AGE=$((CURRENT_TIME - CREATED_TS))
                    [ $AGE -le $STALE_THRESHOLD ] && IS_STALE=0
                fi
            fi
        fi

        # NEVER auto-prune the main static bouncer
        if [ "$full_name" = "traefik-bouncer" ]; then
            # Record status for the group (always active, or staleness handled separately)
            if [ $IS_STALE -eq 0 ]; then
                touch "$GROUP_DIR/${base_name}.active"
            else
                echo "$full_name" >> "$GROUP_DIR/${base_name}.stale_list"
            fi
            continue
        fi

        # Auto-prune very old bouncers — do this BEFORE recording group status.
        # Guard LAST_PULL_TS: if it's empty (last_pull was null), use 0 to avoid arithmetic errors.
        if [ $IS_REALLY_OLD -eq 1 ]; then
            _lpts=${LAST_PULL_TS:-0}
            if [ $_lpts -gt 0 ]; then
                DIFF_H=$(( (CURRENT_TIME - _lpts) / 3600 ))
            else
                DIFF_H=0
            fi
            printf '%b\n' "${YELLOW}🧹 Auto-pruning very old bouncer: $full_name (last pull: ${DIFF_H}h ago)${NC}"
            docker exec "$CROWDSEC_CONTAINER" cscli bouncers delete "$full_name" > /dev/null 2>&1
            continue # Skip to next bouncer — don't record this one in group status
        fi

        # Record status for the group (only for non-pruned bouncers)
        if [ $IS_STALE -eq 0 ]; then
            touch "$GROUP_DIR/${base_name}.active"
        else
            echo "$full_name" >> "$GROUP_DIR/${base_name}.stale_list"
        fi
    done < "$BOUNCER_LIST_FILE"
    rm -f "$BOUNCER_LIST_FILE"
    BOUNCER_LIST_FILE=""

    # Evaluate groups and build alert message
    STALE_ALERTS=""
    for group_file in "$GROUP_DIR"/*.stale_list; do
        [ ! -f "$group_file" ] && continue

        base_name=$(basename "$group_file" .stale_list)

        # Only alert if there are NO active instances in this group
        if [ ! -f "$GROUP_DIR/${base_name}.active" ]; then
            while read -r name; do
                # Find the specific minutes for this name to include in alert
                last_pull=$(echo "$BOUNCERS" | jq -r ".[] | select(.name==\"$name\") | .last_pull" | head -n 1)

                MSG_TIME=""
                if [ -n "$last_pull" ] && [ "$last_pull" != "null" ]; then
                    LAST_PULL_TS=$(date -d "$last_pull" +%s 2>/dev/null)
                    if [ -n "$LAST_PULL_TS" ] && echo "$LAST_PULL_TS" | grep -q '^[0-9]\+$'; then
                        MINUTES=$(((CURRENT_TIME - LAST_PULL_TS) / 60))
                        MSG_TIME="${MINUTES} minutes ago"
                    else
                        MSG_TIME="unknown time"
                    fi
                else
                    MSG_TIME="never"
                fi

                STALE_ALERTS="${STALE_ALERTS}• <b>$name</b>: last pull was ${MSG_TIME}%0A"
                printf '%b\n' "${YELLOW}⚠️ Bouncer '$name' is STALE (last pull: ${MSG_TIME})${NC}"
            done < "$group_file"
        else
            printf '%b\n' "${GREEN}✅ Group '$base_name' is active (some instances are stale but at least one is healthy)${NC}"
        fi
    done

    if [ -n "$STALE_ALERTS" ]; then
        send_telegram "Some bouncers appear to be stale:%0A%0A${STALE_ALERTS}%0A👉 <b>Action Required:</b> Access the host to check CrowdSec log/status. If the issue persists, try restarting it (e.g., <code>make restart crowdsec</code>)."
    fi

    rm -rf "$GROUP_DIR"
    GROUP_DIR=""
fi

# Get current ban statistics
DECISIONS=$(docker exec "$CROWDSEC_CONTAINER" cscli decisions list -o json 2>/dev/null)
DECISION_COUNT=$(echo "$DECISIONS" | jq 'length' 2>/dev/null || echo "0")

if [ "$DECISION_COUNT" = "null" ] || [ -z "$DECISION_COUNT" ]; then
    DECISION_COUNT="0"
fi

printf '%b\n' "${GREEN}📊 Active decisions (bans): $DECISION_COUNT${NC}"

# Get metrics summary
ALERTS_24H=$(docker exec "$CROWDSEC_CONTAINER" cscli alerts list --since 24h -o json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [ "$ALERTS_24H" = "null" ] || [ -z "$ALERTS_24H" ]; then
    ALERTS_24H="0"
fi

printf '%b\n' "${GREEN}📊 Alerts in last 24h: $ALERTS_24H${NC}"

echo ""
echo "✅ CrowdSec health check completed successfully."
echo "📊 Summary:"
echo "   - Container status: running"
echo "   - LAPI: healthy"
echo "   - Registered bouncers: $BOUNCER_COUNT"
echo "   - Active bans: $DECISION_COUNT"
echo "   - Alerts (24h): $ALERTS_24H"
