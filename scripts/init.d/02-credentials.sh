#!/bin/bash

ENV_FILE="${ENV_FILE:-./.env}"
case "$ENV_FILE" in /*|./*|../*) ;; *) ENV_FILE="./$ENV_FILE" ;; esac

# Ensure inherited environment variables don't mask missing credentials or service configs in $ENV_FILE
unset DASHBOARD_SECRET_KEY CROWDSEC_WEB_UI_PASSWORD CROWDSEC_DB_PASSWORD CROWDSEC_LAPI_KEY REDIS_PASSWORD ANUBIS_REDIS_PRIVATE_KEY PROMETHEUS_REMOTE_WRITE_TOKEN DASHBOARD_ANUBIS_SUBDOMAIN

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

echo ""
echo "── [2/6] 🔐 Synchronizing credentials & paths ──────────────────────────"

# Helper to perform common hashing (portability between Linux/macOS)
# Usage: echo -n "string" | generate_hash  OR  cat file | generate_hash
generate_hash() {
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum | cut -d' ' -f1
    else
        shasum | cut -d' ' -f1
    fi
}

# Helper to update variables in .env efficiently
# Handles values containing '#' by escaping them for sed
update_env_var() {
    local var_name=$1
    local new_val=$2
    
    # Check if variable exists and extract current value properly (stripping quotes/spaces)
    # Using awk for precision parsing: find line starting with name=, get everything after =
    local current_val=$(awk -F= -v name="$var_name" '$1 == name { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]*["'\'']?|["'\'']?[[:space:]]*$/, ""); print; exit }' "$ENV_FILE")
    
    if [ "$current_val" = "$new_val" ]; then
        # Value is functionally identical. Avoid touching the file to maintain mtime.
        return
    fi
    
    # Ensure values containing whitespace are wrapped in quotes for shell safety
    if [[ "$new_val" =~ [[:space:]] ]] && [[ ! "$new_val" =~ ^\".*\"$ ]] && [[ ! "$new_val" =~ ^\'.*\'$ ]]; then
        new_val="\"$new_val\""
    fi

    # If different (or doesn't exist), update the line safely using awk + ENVIRON
    # This handles ALL special characters (\, |, &, quotes) without delimiter hell.
    local TMP_ENV=$(mktemp)
    NEW_VAL="$new_val" awk -v name="$var_name" '
        BEGIN { FS="="; val=ENVIRON["NEW_VAL"]; found=0 }
        $1 == name { print name "=" val; found=1; next }
        { print }
        END { if (found == 0) print name "=" val }
    ' "$ENV_FILE" > "$TMP_ENV"
    
    cat "$TMP_ENV" > "$ENV_FILE"
    rm "$TMP_ENV"
    chmod 600 "$ENV_FILE"
}

# Dashboard Secret Key (auto-generate on first run)
if [ -z "$DASHBOARD_SECRET_KEY" ] || [ "$DASHBOARD_SECRET_KEY" == "REPLACE_ME" ]; then
    echo "   🔄 Generating Dashboard secret key..."
    NEW_DM_KEY=$(openssl rand -hex 32)
    update_env_var "DASHBOARD_SECRET_KEY" "$NEW_DM_KEY"
    export DASHBOARD_SECRET_KEY="$NEW_DM_KEY"
fi

# CrowdSec Web UI Password (auto-generate on first run if CrowdSec is enabled)
if [ "${CROWDSEC_ENABLE:-true}" != "false" ]; then
    if [ -z "$CROWDSEC_WEB_UI_PASSWORD" ] || [ "$CROWDSEC_WEB_UI_PASSWORD" == "REPLACE_ME" ]; then
        echo "   🔄 Generating CrowdSec Web UI internal password..."
        NEW_CS_UI_PASS=$(openssl rand -hex 32)
        update_env_var "CROWDSEC_WEB_UI_PASSWORD" "$NEW_CS_UI_PASS"
        export CROWDSEC_WEB_UI_PASSWORD="$NEW_CS_UI_PASS"
    fi

    # CrowdSec PostgreSQL Database Password (auto-generate on first run if CrowdSec is enabled)
    if [ -z "$CROWDSEC_DB_PASSWORD" ] || [ "$CROWDSEC_DB_PASSWORD" == "REPLACE_ME" ]; then
        echo "   🔄 Generating CrowdSec PostgreSQL DB password..."
        NEW_CS_DB_PASS=$(openssl rand -hex 32)
        update_env_var "CROWDSEC_DB_PASSWORD" "$NEW_CS_DB_PASS"
        export CROWDSEC_DB_PASSWORD="$NEW_CS_DB_PASS"
    fi

    # CrowdSec Local API Key (auto-generate on first run or if too short)
    # Minimum 32 characters enforced — shorter keys don't meet entropy requirements.
    if [ -z "$CROWDSEC_LAPI_KEY" ] || [ "$CROWDSEC_LAPI_KEY" == "REPLACE_ME" ] || [ ${#CROWDSEC_LAPI_KEY} -lt 32 ]; then
        echo "   🔄 Generating secure CrowdSec Local API key..."
        NEW_CS_LAPI_KEY=$(openssl rand -hex 32)
        update_env_var "CROWDSEC_LAPI_KEY" "$NEW_CS_LAPI_KEY"
        export CROWDSEC_LAPI_KEY="$NEW_CS_LAPI_KEY"
    fi
fi

# Redis Password (auto-generate on first run or if too short)
# Alphanumeric-only (hex) to avoid URL-encoding issues in redis:// connection strings.
# Minimum 20 characters enforced (32 hex characters = 128 bits of entropy).
if [ -z "$REDIS_PASSWORD" ] || [ "$REDIS_PASSWORD" == "REPLACE_ME" ] || [ ${#REDIS_PASSWORD} -lt 20 ]; then
    echo "   🔄 Generating secure random Redis password..."
    NEW_REDIS_PASS=$(openssl rand -hex 16)
    update_env_var "REDIS_PASSWORD" "$NEW_REDIS_PASS"
    export REDIS_PASSWORD="$NEW_REDIS_PASS"
fi

# Anubis Redis Private Key (auto-generate on first run if Anubis is used)
HAS_ANUBIS=0
if [ -f .anubis_available ]; then
    HAS_ANUBIS=1
elif [ -n "$DASHBOARD_ANUBIS_SUBDOMAIN" ]; then
    HAS_ANUBIS=1
elif [ -f domains.csv ] && awk -F',' '!/^#/ && $4 != "" { found=1; exit } END { exit !found }' domains.csv 2>/dev/null; then
    HAS_ANUBIS=1
fi

if [ "$HAS_ANUBIS" -eq 1 ]; then
    if [ -z "$ANUBIS_REDIS_PRIVATE_KEY" ] || [ "$ANUBIS_REDIS_PRIVATE_KEY" == "REPLACE_ME" ]; then
        echo "   🔄 Generating secure Anubis Redis private key..."
        NEW_ANUBIS_KEY=$(openssl rand -hex 32)
        update_env_var "ANUBIS_REDIS_PRIVATE_KEY" "$NEW_ANUBIS_KEY"
        export ANUBIS_REDIS_PRIVATE_KEY="$NEW_ANUBIS_KEY"
    fi
fi

# Prometheus Remote Write Token (auto-generate on first run if Observability is enabled)
if [ "${GRAFANA_ENABLED:-true}" != "false" ]; then
    if [ -z "$PROMETHEUS_REMOTE_WRITE_TOKEN" ] || [ "$PROMETHEUS_REMOTE_WRITE_TOKEN" == "REPLACE_ME" ]; then
        echo "   🔄 Generating Prometheus remote-write token..."
        NEW_PROM_TOKEN=$(openssl rand -hex 32)
        update_env_var "PROMETHEUS_REMOTE_WRITE_TOKEN" "$NEW_PROM_TOKEN"
        export PROMETHEUS_REMOTE_WRITE_TOKEN="$NEW_PROM_TOKEN"
    fi
fi

# Source ENV_FILE once to load all newly generated variables
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Clean any leading/trailing quotes from CROWDSEC_COLLECTIONS to prevent duplicate quoting from Make/OS
if [ -n "$CROWDSEC_COLLECTIONS" ]; then
    CROWDSEC_COLLECTIONS=$(echo "$CROWDSEC_COLLECTIONS" | tr -d '"' | tr -d "'" | xargs)
    export CROWDSEC_COLLECTIONS
fi

# =============================================================================
# AUTO-CONFIGURATION: Absolute Path Mirroring
# =============================================================================
# Calculate the absolute path of the project on the host and ensure it is set 
# in .env. This is critical for Docker's working_dir and volume mirroring.

# Use realpath if available, otherwise fallback to readlink -f or pwd -P
if command -v realpath >/dev/null 2>&1; then
    DETECTED_PATH=$(realpath .)
elif command -v readlink >/dev/null 2>&1; then
    DETECTED_PATH=$(readlink -f .)
else
    DETECTED_PATH=$(pwd -P)
fi

# Check if it is currently set in .env
ENV_VAL=$(awk -F= -v name="DASHBOARD_APP_PATH_HOST" '$1 == name { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]*["'\'']?|["'\'']?[[:space:]]*$/, ""); print; exit }' "$ENV_FILE")

if [ -z "$ENV_VAL" ] || [ "$ENV_VAL" == "REPLACE_ME" ] || [ "$ENV_VAL" == "null" ]; then
    PATH_TO_WRITE="${DASHBOARD_APP_PATH_HOST:-$DETECTED_PATH}"
    if [ "$PATH_TO_WRITE" == "REPLACE_ME" ] || [ "$PATH_TO_WRITE" == "null" ] || [ -z "$PATH_TO_WRITE" ]; then
        PATH_TO_WRITE="$DETECTED_PATH"
    fi
    update_env_var "DASHBOARD_APP_PATH_HOST" "$PATH_TO_WRITE"
    export DASHBOARD_APP_PATH_HOST="$PATH_TO_WRITE"
    echo "   ✅ Project path initialized in .env: $PATH_TO_WRITE"
else
    export DASHBOARD_APP_PATH_HOST="$ENV_VAL"
fi

# Calculate PROJECTS_DIR dynamically as the parent directory of DASHBOARD_APP_PATH_HOST
DETECTED_PROJECTS_DIR=$(dirname "$DASHBOARD_APP_PATH_HOST")
update_env_var "PROJECTS_DIR" "$DETECTED_PROJECTS_DIR"
export PROJECTS_DIR="$DETECTED_PROJECTS_DIR"


# Normalize CROWDSEC_ENABLE to lowercase and strip quotes/whitespace
CROWDSEC_ENABLE=$(echo "${CROWDSEC_ENABLE:-true}" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
export CROWDSEC_ENABLE

# Normalize CROWDSEC_APPSEC_ENABLE to lowercase and strip quotes/whitespace
CROWDSEC_APPSEC_ENABLE=$(echo "${CROWDSEC_APPSEC_ENABLE:-true}" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
export CROWDSEC_APPSEC_ENABLE

# Normalize GRAFANA_ENABLED to lowercase and strip quotes/whitespace (defaults to true)
GRAFANA_ENABLED=$(echo "${GRAFANA_ENABLED:-${GRAFANA_ENABLE:-true}}" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
export GRAFANA_ENABLED

# Normalize WATCHDOG_ENABLE to lowercase and strip quotes/whitespace
WATCHDOG_ENABLE=$(echo "${WATCHDOG_ENABLE:-${WATCHDOG_ENABLED:-true}}" | tr -d '\"'\'' ' | tr '[:upper:]' '[:lower:]')
export WATCHDOG_ENABLE

