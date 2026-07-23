#!/bin/bash


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
    
    if [ "$current_val" == "$new_val" ]; then
        # Value is functionally identical. Avoid touching the file to maintain mtime.
        return
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

# CrowdSec Web UI Password (auto-generate on first run)
if [ -z "$CROWDSEC_WEB_UI_PASSWORD" ] || [ "$CROWDSEC_WEB_UI_PASSWORD" == "REPLACE_ME" ]; then
    echo "   🔄 Generating CrowdSec Web UI internal password..."
    NEW_CS_UI_PASS=$(openssl rand -hex 32)
    update_env_var "CROWDSEC_WEB_UI_PASSWORD" "$NEW_CS_UI_PASS"
    export CROWDSEC_WEB_UI_PASSWORD="$NEW_CS_UI_PASS"
fi

# CrowdSec PostgreSQL Database Password (auto-generate on first run)
if [ -z "$CROWDSEC_DB_PASSWORD" ] || [ "$CROWDSEC_DB_PASSWORD" == "REPLACE_ME" ]; then
    echo "   🔄 Generating CrowdSec PostgreSQL DB password..."
    NEW_CS_DB_PASS=$(openssl rand -hex 32)
    update_env_var "CROWDSEC_DB_PASSWORD" "$NEW_CS_DB_PASS"
    export CROWDSEC_DB_PASSWORD="$NEW_CS_DB_PASS"
fi

# Redis Password (auto-generate on first run or if too short)
# Alphanumeric-only to avoid URL-encoding issues in redis:// connection strings.
# Minimum 20 characters enforced (119 bits of entropy from the base64 source).
if [ -z "$REDIS_PASSWORD" ] || [ "$REDIS_PASSWORD" == "REPLACE_ME" ] || [ ${#REDIS_PASSWORD} -lt 20 ]; then
    echo "   🔄 Generating secure random Redis password..."
    NEW_REDIS_PASS=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)
    update_env_var "REDIS_PASSWORD" "$NEW_REDIS_PASS"
    export REDIS_PASSWORD="$NEW_REDIS_PASS"
fi



# Anubis Redis Private Key (auto-generate on first run)
if [ -z "$ANUBIS_REDIS_PRIVATE_KEY" ] || [ "$ANUBIS_REDIS_PRIVATE_KEY" == "REPLACE_ME" ]; then
    echo "   🔄 Generating secure Anubis Redis private key..."
    NEW_ANUBIS_KEY=$(openssl rand -hex 32)
    update_env_var "ANUBIS_REDIS_PRIVATE_KEY" "$NEW_ANUBIS_KEY"
    export ANUBIS_REDIS_PRIVATE_KEY="$NEW_ANUBIS_KEY"
fi

# CrowdSec Local API Key (auto-generate on first run or if too short)
# Minimum 32 characters enforced — shorter keys don't meet entropy requirements.
if [ -z "$CROWDSEC_LAPI_KEY" ] || [ "$CROWDSEC_LAPI_KEY" == "REPLACE_ME" ] || [ ${#CROWDSEC_LAPI_KEY} -lt 32 ]; then
    echo "   🔄 Generating secure CrowdSec Local API key..."
    NEW_CS_LAPI_KEY=$(openssl rand -hex 32)
    update_env_var "CROWDSEC_LAPI_KEY" "$NEW_CS_LAPI_KEY"
    export CROWDSEC_LAPI_KEY="$NEW_CS_LAPI_KEY"
fi

# Source .env once to load all newly generated variables
set -a
source .env
set +a

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


# Normalize CROWDSEC_ENABLE to lowercase
CROWDSEC_ENABLE=$(echo "${CROWDSEC_ENABLE:-true}" | tr '[:upper:]' '[:lower:]')

# Normalize CROWDSEC_APPSEC_ENABLE to lowercase
CROWDSEC_APPSEC_ENABLE=$(echo "${CROWDSEC_APPSEC_ENABLE:-true}" | tr '[:upper:]' '[:lower:]')

