#!/bin/bash
set -e

echo "============================================="
echo "       STACK GLOBAL HEALTH CHECK             "
echo "============================================="

# Load environment
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi
source scripts/compose-files.sh
DOCKER_COMPOSE="docker compose -p ${PROJECT_NAME:-traefik-stack} $COMPOSE_FILES"

check_container() {
    local service=$1
    local cmd=$2
    if [ -z "$($DOCKER_COMPOSE ps -q $service)" ]; then
        echo -e "🔴 \033[1m$service\033[0m: Container is down"
        return 1
    fi
    if $DOCKER_COMPOSE exec -T $service $cmd >/dev/null 2>&1; then
        echo -e "🟢 \033[1m$service\033[0m: Healthy & Responding"
        return 0
    else
        echo -e "🔴 \033[1m$service\033[0m: Container is up, but healthcheck failed"
        return 1
    fi
}

check_perms() {
    local file=$1
    if [ -f "$file" ]; then
        # Handle mac/linux stat differences to support running on macOS host
        perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%A' "$file" 2>/dev/null)
        if [ "$perms" == "600" ]; then
            echo -e "🟢 \033[1mSecurity ($file)\033[0m: Correct permissions ($perms)"
        else
            echo -e "🔴 \033[1mSecurity ($file)\033[0m: WARNING! Insecure permissions ($perms, expected 600)"
        fi
    else
        echo -e "🟡 \033[1mSecurity ($file)\033[0m: File not found (skipping)"
    fi
}

echo ""
echo "--- Security & Permissions ---"
check_perms ".env"
check_perms "config/traefik/acme.json"

echo ""
echo "--- Infrastructure ---"
check_container "traefik" "traefik healthcheck"
if [ "$CROWDSEC_ENABLE" != "false" ]; then
    check_container "crowdsec" "cscli lapi status"
    if [ "${CROWDSEC_APPSEC_ENABLE:-true}" != "false" ]; then
        if $DOCKER_COMPOSE exec -T crowdsec sh -c 'wget -qO- http://localhost:7422/ 2>&1 | grep -q "401 Unauthorized"' >/dev/null 2>&1; then
            echo -e "🟢 \033[1mcrowdsec-appsec\033[0m: WAF Listening & Responding"
        else
            echo -e "🔴 \033[1mcrowdsec-appsec\033[0m: WAF is down / not listening on port 7422"
        fi
    fi
else
    echo -e "🟡 \033[1mcrowdsec\033[0m: Disabled in .env"
fi
# Since the image is Valkey-based, valkey-cli is guaranteed to be available.
check_container "redis" "valkey-cli -a ${REDIS_PASSWORD} ping"

echo ""
echo "--- Observability ---"
check_container "grafana" "wget -qO- http://localhost:3000/api/health"

echo ""
echo "============================================="
