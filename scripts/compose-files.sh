#!/bin/bash

# =============================================================================
# compose-files.sh - Shared Compose File List Builder
# =============================================================================
# Single source of truth for the Docker Compose file list.
# Sourced by: start.sh, stop.sh, Makefile
#
# Exports: COMPOSE_FILES (string of -f flags)
#
# Usage:
#   source scripts/compose-files.sh          # from project root
#   source "$SCRIPT_DIR/compose-files.sh"    # from another script
# =============================================================================

# Base compose files (always included)
COMPOSE_FILES="-f docker-compose-traefik-crowdsec-redis.yaml \
               -f docker-compose-tools.yaml \
               -f docker-compose-grafana-loki-alloy-prometheus.yaml \
               -f docker-compose-domain-manager.yaml"

# Add CrowdSec Web UI if enabled
if [[ "${CROWDSEC_ENABLE:-true}" == "true" ]]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-crowdsec-web-ui.yaml"
fi

# Add Anubis if generated config exists
if [ -f "docker-compose-anubis-generated.yaml" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-anubis-generated.yaml"
fi

# Add Apache logs if host Apache was detected (flag set by start.sh)
if [ -f ".apache_host_available" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-apache-logs.yaml"
fi

export COMPOSE_FILES
