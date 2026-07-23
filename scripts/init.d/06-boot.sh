#!/bin/bash

echo ""
echo "── [5/6] 👮 Booting security layer ─────────────────────────────────────"

if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
    # Smart check: Is it already running and healthy?
    CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
    CS_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CROWDSEC_ID" 2>/dev/null || echo "none")

    if [ "$CS_STATUS" == "healthy" ]; then
        $COMPOSE_CMD --progress quiet $COMPOSE_FILES up -d crowdsec > /dev/null
        sleep 1 # Allow time for recreation if compose detected a change

        # Refresh ID — container may have been recreated due to config changes
        CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)

        # Wait for healthy in case of recreation
        timeout=60
        while [ -z "$CROWDSEC_ID" ] || [ "$(docker inspect --format='{{.State.Health.Status}}' $CROWDSEC_ID 2>/dev/null)" != "healthy" ]; do
            sleep 2
            ((timeout-=2))
            if [ $timeout -le 0 ]; then
                echo "   ❌ Timeout waiting for CrowdSec to become healthy after config update."
                exit 1
            fi
            CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
        done
    else
        echo -n "   ⏳ Starting security services (CrowdSec, PostgreSQL & Redis)..."
        $COMPOSE_CMD --progress quiet $COMPOSE_FILES up -d crowdsec-db crowdsec redis > /dev/null
        sleep 1 # Allow terminal to settle

        # Wait for CrowdSec to be healthy
        timeout=60
        # Refresh ID in case it was just created
        CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
        
        while [ -z "$CROWDSEC_ID" ] || [ "$(docker inspect --format='{{.State.Health.Status}}' $CROWDSEC_ID 2>/dev/null)" != "healthy" ]; do
            sleep 2
            echo -n "."
            ((timeout-=2))
            if [ $timeout -le 0 ]; then
                echo ""
                echo "   ❌ Timeout waiting for CrowdSec to become healthy."
                exit 1
            fi
            CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
        done
        echo " ready!"
    fi

    # =============================================================================
    # PHASE 5: Register Bouncer API Key
    # =============================================================================
    # Re-register the Traefik Bouncer key on each start to ensure consistency.
    #
    # Strategy to avoid the delete→add race condition:
    #   1. Try to ADD first — succeeds immediately on a fresh CrowdSec database.
    #   2. If the bouncer already exists (exit ≠ 0), THEN delete and re-add.
    #      The window where no bouncer exists is reduced to a single docker exec
    #      round-trip (~100ms) rather than two sequential calls.

    ADD_EXIT=0
    ADD_OUTPUT=$(echo "${CROWDSEC_LAPI_KEY}" | docker exec -i "$CROWDSEC_ID" sh -c 'read -r KEY && cscli bouncers add traefik-bouncer --key "$KEY"' 2>&1) || ADD_EXIT=$?

    if [ $ADD_EXIT -ne 0 ]; then
        # Bouncer already registered — delete it and immediately re-add with the current key.
        docker exec "$CROWDSEC_ID" cscli bouncers delete traefik-bouncer > /dev/null 2>&1 || true
        ADD_EXIT=0
        ADD_OUTPUT=$(echo "${CROWDSEC_LAPI_KEY}" | docker exec -i "$CROWDSEC_ID" sh -c 'read -r KEY && cscli bouncers add traefik-bouncer --key "$KEY"' 2>&1) || ADD_EXIT=$?
    fi

    if [ $ADD_EXIT -ne 0 ]; then
        echo "❌ Error registering bouncer key: $ADD_OUTPUT"
        exit 1
    fi

    # =============================================================================
    # PHASE 5: Register Web UI Machine
    # =============================================================================
    # Register the Web UI machine to allow it to communicate with LAPI.
    # We use -f /dev/null to avoid overwriting the local credentials of the crowdsec container itself.
    
    # Settings are loaded natively via mounted /etc/crowdsec/config.yaml.local override
    docker exec "$CROWDSEC_ID" kill -HUP 1 > /dev/null 2>&1 || true

    docker exec "$CROWDSEC_ID" cscli machines delete "${CROWDSEC_WEB_UI_USER:-crowdsec-web-ui}" > /dev/null 2>&1 || true
    docker exec -e CROWDSEC_WEB_UI_PASSWORD="${CROWDSEC_WEB_UI_PASSWORD}" "$CROWDSEC_ID" sh -c 'cscli machines add "${CROWDSEC_WEB_UI_USER:-crowdsec-web-ui}" --password "$CROWDSEC_WEB_UI_PASSWORD" -f /dev/null' > /dev/null 2>&1 || true

    # =============================================================================
    # PHASE 5: CrowdSec Console Enrollment (Optional)
    # =============================================================================
    # If CROWDSEC_ENROLLMENT_KEY is set, enroll this instance with CrowdSec Console
    # for access to community blocklists and centralized management.

    if [ -n "$CROWDSEC_ENROLLMENT_KEY" ] && [ "$CROWDSEC_ENROLLMENT_KEY" != "REPLACE_ME" ]; then
        docker exec "$CROWDSEC_ID" cscli console enroll "$CROWDSEC_ENROLLMENT_KEY" --name "$(hostname)" >/dev/null 2>&1 || true
    fi

    echo "   ✅ CrowdSec & Redis operational."
else
    REDIS_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=redis | head -n 1)
    if [ -n "$REDIS_ID" ] && [ "$(docker inspect --format='{{.State.Running}}' $REDIS_ID 2>/dev/null)" == "true" ]; then
        :
    else
        echo -n "   ⏳ Starting Redis..."
        $COMPOSE_CMD --progress quiet $COMPOSE_FILES up -d redis > /dev/null
        sleep 1
        echo " ready!"
    fi
    echo "   ✅ Redis operational."
fi

# =============================================================================
# PHASE 6: Deploy Remaining Services
# =============================================================================
# Now that the security layer is ready, deploy everything else.
# --remove-orphans cleans up any old containers not in current config.


echo ""
echo "── [6/6] 🚀 Deploying remaining services ───────────────────────────────"
# If running inside dashboard, we perform a 'Config Audit' first to detect shifts.
if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
    echo "   🔍 Auditing docker-compose configuration for drift..."
    # This helps us see which variables are causing recreations in the modal log
    $COMPOSE_CMD $COMPOSE_FILES config --quiet || echo "      ⚠️ Warning: Config validation failed."
fi

# Deploy everything.
echo "   ⏳ Deploying stack containers..."
$COMPOSE_CMD --progress quiet $COMPOSE_FILES up -d --remove-orphans
sleep 1
echo "   ✅ Services started successfully."

echo "   🔍 Verifying Core DNS records..."
CORE_SUBS=("dashboard")
MISSING_DNS=()

# Helper for DNS resolution (cross-platform)
resolve_host() {
    local host="$1"
    
    # 0. Check /etc/hosts first (Reliable for local dev, respects $HOSTS_FILE)
    local escaped_host="${host//./\\.}"
    if grep -qE "[[:space:]]${escaped_host}([[:space:]]|$)" "$HOSTS_FILE"; then
        return 0
    fi

    # 1. System-level resolution
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$host" >/dev/null 2>&1
        return $?
    elif command -v dscacheutil >/dev/null 2>&1; then
        # macOS specific resolution check
        dscacheutil -q host -a name "$host" | grep -q "ip_address:"
        return $?
    elif command -v ping >/dev/null 2>&1; then
        # Ping as fallback for resolution (timeout 1s)
        ping -c 1 -W 1 "$host" >/dev/null 2>&1 || ping -c 1 -t 1 "$host" >/dev/null 2>&1
        return $?
    elif command -v host >/dev/null 2>&1; then
        # DNS only (will ignore /etc/hosts)
        host -t A "$host" >/dev/null 2>&1
        return $?
    fi
    return 1
}

for sub in "${CORE_SUBS[@]}"; do
    TARGET_FQDN="$sub.$DOMAIN"
    if ! resolve_host "$TARGET_FQDN"; then
        MISSING_DNS+=("$TARGET_FQDN")
    fi
done

if [ ${#MISSING_DNS[@]} -gt 0 ]; then
    echo "      ⚠️ The following core subdomains are not resolvable:"
    for m in "${MISSING_DNS[@]}"; do
        echo "         ➜ $m"
    done
    echo "      👉 ACTION REQUIRED: Please create these DNS records (Type A) pointing to this server."
else
    echo "      ✅ All core DNS records verified."
fi

# =============================================================================
# Grafana Alerting Setup
# =============================================================================
if [ -f "./scripts/setup-grafana-alerting.sh" ]; then
    bash ./scripts/setup-grafana-alerting.sh
fi

