#!/bin/bash

# =============================================================================
# stop.sh - Stack Shutdown Script
# =============================================================================
# Stops all containers and cleans up orphaned containers from removed domains.
# =============================================================================

# =============================================================================
# PHASE 1: Load Environment Variables
# =============================================================================
# Load variables to avoid Docker warnings during the down process.

set -a
# Try to load .env if it exists
[ -f .env ] && source .env
set +a

export PROJECT_NAME=${PROJECT_NAME:-"stack"}

# Verify TRAEFIK_CERT_RESOLVER to suppress warnings
if [ -z "$TRAEFIK_CERT_RESOLVER" ]; then
    if [ "$TRAEFIK_ACME_ENV_TYPE" == "local" ]; then
        export TRAEFIK_CERT_RESOLVER=""
    else
        export TRAEFIK_CERT_RESOLVER="le"
    fi
fi

set -e  # Exit on any error

# =============================================================================
# TERMINAL RESTORATION
# =============================================================================
# Ensures the cursor is restored and echo is enabled if the script is interrupted.

cleanup() {
    set +e
    if [ -t 0 ]; then
        tput cnorm 2>/dev/null || true
        stty echo 2>/dev/null || true
    fi
    return 0
}

trap cleanup EXIT INT TERM

# =============================================================================
# PHASE 2: Build Compose File List
# =============================================================================
# Uses shared script to ensure consistency with start.sh and Makefile.

# Safety check: if docker-compose-anubis-generated.yaml is a directory (Docker artifact), remove it
if [ -d "docker-compose-anubis-generated.yaml" ]; then
    echo "⚠️  Cleaning up directory collision: docker-compose-anubis-generated.yaml"
    rm -rf docker-compose-anubis-generated.yaml
fi

# Safety check: if domains.csv is a directory (Docker artifact), remove it
if [ -d "domains.csv" ]; then
    echo "⚠️  Cleaning up directory collision: domains.csv"
    rm -rf domains.csv
fi

source scripts/compose-files.sh

# =============================================================================
# PHASE 3: Stop All Services
# =============================================================================
# --remove-orphans cleans containers for domains that were deleted from the CSV
# and no longer exist in the generated docker-compose files.

echo "🛑 Stopping and cleaning the entire stack..."

# Enforce project name to avoid missing containers
COMPOSE_CMD="docker compose -p $PROJECT_NAME"
if [ "${CROWDSEC_ENABLE:-true}" = "true" ]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile crowdsec"
fi

# 1. Graceful stop (allow containers to finish tasks)
# We use || true to ensure 'down' runs even if 'stop' encounters issues
echo "   ➜ Stopping services gracefully (20s timeout)..."
$COMPOSE_CMD $COMPOSE_FILES stop -t 20 || true

# 2. Complete removal
echo "   ➜ Removing containers and cleaning orphans..."
$COMPOSE_CMD $COMPOSE_FILES down --remove-orphans

# =============================================================================
# DONE
# =============================================================================

echo ""
echo "✅ Project stopped and clean."
echo ""
