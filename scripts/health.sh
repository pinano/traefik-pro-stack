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
        # Handle mac/linux stat differences if necessary, but assume linux
        perms=$(stat -c %a "$file")
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
else
    echo -e "🟡 \033[1mcrowdsec\033[0m: Disabled in .env"
fi
check_container "redis" "redis-cli -a ${REDIS_PASSWORD:-} PING"

echo ""
echo "--- Observability ---"
check_container "grafana" "curl -s -f http://localhost:3000/api/health"

echo ""
echo "============================================="
