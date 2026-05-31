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
COMPOSE_FILES="-f docker-compose-edge.yaml \
               -f docker-compose-security.yaml \
               -f docker-compose-observability.yaml \
               -f docker-compose-dashboard.yaml"

# Add Anubis if enabled (base template + assets)
COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-anubis.yaml"

# Add Anubis if generated config exists
if [ -f "docker-compose-anubis-generated.yaml" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-anubis-generated.yaml"
fi

# Add Apache logs if host Apache was detected (flag set by start.sh)
if [ -f ".apache_host_available" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-apache-logs.yaml"
fi

# Add Maintenance container if mode is active
if [ -f ".maintenance_mode" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-maintenance.yaml"
fi

# Add Backrest (Restic Web UI) if enabled
BACKREST_ENABLE="${BACKREST_ENABLE:-true}"
if [ "$BACKREST_ENABLE" = "true" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-backrest.yaml"
fi

export COMPOSE_FILES
