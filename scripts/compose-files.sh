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

# If environment variables are not exported in caller, read them safely from .env
ENV_CANDIDATE=""
if [ -f "./.env" ]; then
    ENV_CANDIDATE="./.env"
elif [ -f "../.env" ]; then
    ENV_CANDIDATE="../.env"
fi

if [ -n "$ENV_CANDIDATE" ]; then
    if [ -z "$GRAFANA_ENABLED" ] && [ -z "$GRAFANA_ENABLE" ]; then
        GRAFANA_ENABLED=$(grep -E '^[[:space:]]*GRAFANA_ENABLE(D)?=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
    if [ -z "$WATCHDOG_ENABLE" ] && [ -z "$WATCHDOG_ENABLED" ]; then
        WATCHDOG_ENABLE=$(grep -E '^[[:space:]]*WATCHDOG_ENABLE(D)?=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
    if [ -z "$BACKREST_ENABLE" ]; then
        BACKREST_ENABLE=$(grep -E '^[[:space:]]*BACKREST_ENABLE=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
    if [ -z "$PHPMYADMIN_ENABLE" ]; then
        PHPMYADMIN_ENABLE=$(grep -E '^[[:space:]]*PHPMYADMIN_ENABLE=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
    if [ -z "$FILEBROWSER_ENABLE" ]; then
        FILEBROWSER_ENABLE=$(grep -E '^[[:space:]]*FILEBROWSER_ENABLE=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
    if [ -z "$TRAEFIK_ACME_ENV_TYPE" ]; then
        TRAEFIK_ACME_ENV_TYPE=$(grep -E '^[[:space:]]*TRAEFIK_ACME_ENV_TYPE=' "$ENV_CANDIDATE" 2>/dev/null | cut -d= -f2- | tr -d '\"'\'' ')
    fi
fi

# Base compose files (always included)
COMPOSE_FILES="-f docker-compose-edge.yaml \
               -f docker-compose-security.yaml \
               -f docker-compose-dashboard.yaml"

# Add Observability (Grafana, Loki, Alloy, Prometheus) if enabled (defaults to true)
GRAFANA_ENABLED_VAL="${GRAFANA_ENABLED:-${GRAFANA_ENABLE:-true}}"
GRAFANA_ENABLED_VAL=$(echo "$GRAFANA_ENABLED_VAL" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
if [ "$GRAFANA_ENABLED_VAL" != "false" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-observability.yaml"
fi

# Add Watchdog (SSL, DNS, CrowdSec health monitor) if enabled (defaults to false in local, true in staging/prod)
WATCHDOG_ENABLED_VAL="${WATCHDOG_ENABLE:-${WATCHDOG_ENABLED:-}}"
if [ -z "$WATCHDOG_ENABLED_VAL" ]; then
    if [ "${TRAEFIK_ACME_ENV_TYPE:-local}" = "local" ]; then
        WATCHDOG_ENABLED_VAL="false"
    else
        WATCHDOG_ENABLED_VAL="true"
    fi
fi
WATCHDOG_ENABLED_VAL=$(echo "$WATCHDOG_ENABLED_VAL" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
if [ "$WATCHDOG_ENABLED_VAL" != "false" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-watchdog.yaml"
fi

# Add Anubis if active domains exist (flag set by generate-config.py)
if [ -f ".anubis_available" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-anubis.yaml"
    if [ -f "docker-compose-anubis-generated.yaml" ]; then
        COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-anubis-generated.yaml"
    fi
fi

# Add Apache logs if host Apache was detected and observability is enabled
if [ -f ".apache_host_available" ] && [ "$GRAFANA_ENABLED_VAL" != "false" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-apache-logs.yaml"
fi

# Add Maintenance container if mode is active
if [ -f ".maintenance_mode" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-maintenance.yaml"
fi

# Add Backrest (Restic Web UI) if enabled
BACKREST_ENABLE="${BACKREST_ENABLE:-false}"
if [ "$BACKREST_ENABLE" = "true" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-backrest.yaml"
fi

# Add phpMyAdmin if enabled
PHPMYADMIN_ENABLE="${PHPMYADMIN_ENABLE:-false}"
if [ "$PHPMYADMIN_ENABLE" = "true" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-phpmyadmin.yaml"
fi

# Add Filebrowser if enabled
FILEBROWSER_ENABLE="${FILEBROWSER_ENABLE:-false}"
if [ "$FILEBROWSER_ENABLE" = "true" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-filebrowser.yaml"
fi

export COMPOSE_FILES
