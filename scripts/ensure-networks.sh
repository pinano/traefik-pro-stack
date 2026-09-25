#!/bin/bash
# =============================================================================
# Ensure Docker Networks Exist
# =============================================================================
# Creates all external Docker networks required by the stack.
# Called by start.sh, update.sh, and make rebuild to guarantee
# networks exist before docker compose up runs.
# =============================================================================

for net in traefik socket-proxy socket-proxy-dashboard anubis-backend crowdsec-backend; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        if [ "$net" == "traefik" ]; then
            docker network create "$net" >/dev/null
        else
            docker network create --internal "$net" >/dev/null
        fi
        echo "   ✅ Created $net network."
    fi
done
