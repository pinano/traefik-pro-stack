#!/bin/bash

# =============================================================================
# start.sh - Stack Deployment Script
# =============================================================================
# Loads configuration, prepares networks, and deploys the stack safely,
# ensuring security components (CrowdSec/Redis) are operational first.
# =============================================================================

set -e  # Exit on any error

# ⏲️ Start Timer
START_TIME=$(date +%s)

# 0. Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running. Please start Docker and try again."
    exit 1
fi

echo ""
echo "========================================================"
echo "🚀 DEPLOYMENT STARTING..."
echo "========================================================"
echo ""

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

# Determine which hosts file to use (support for running inside dashboard container)
HOSTS_FILE="/etc/hosts"
if [ -f "/etc/hosts-host" ]; then
    HOSTS_FILE="/etc/hosts-host"
fi

trap cleanup EXIT INT TERM

# Ensures .env exists and is up to date with .env.dist structure.

DIST_FILE=".env.dist"
ENV_FILE=".env"

# 1. Check if .env exists, if not, initialize
if [ ! -f "$ENV_FILE" ]; then
    echo "⚠️  $ENV_FILE not found. Running initialization..."
    if [ -f "./scripts/initialize-env.sh" ]; then
        [ -w "./scripts/initialize-env.sh" ] && chmod +x ./scripts/initialize-env.sh
        ./scripts/initialize-env.sh
        exit 0
    else
        echo "❌ Error: initialize-env.sh not found. Please create $ENV_FILE manually."
        exit 1
    fi
fi

# 1. Environment Preparation
echo " --------------------------------------------------------"
echo " [1/6] 📋 Preparing environment..."
TEMP_ENV=$(mktemp)
ADDED_VARS=0
cp "$ENV_FILE" "${ENV_FILE}.bak"

# Process all lines from .env.dist to maintain its structure
while IFS= read -r line || [ -n "$line" ]; do
    # Preserve comments and empty lines
    if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
        echo "$line" >> "$TEMP_ENV"
        continue
    fi

    # Extract variable name (part before =)
    VAR_NAME=$(echo "$line" | cut -d'=' -f1)
    
    # Check if variable exists in current .env
    if grep -q "^${VAR_NAME}=" "$ENV_FILE"; then
        # Use existing value from .env (take the first occurrence)
        grep "^${VAR_NAME}=" "$ENV_FILE" | head -n 1 >> "$TEMP_ENV"
    else
        # Use default value from .env.dist
        echo "$line" >> "$TEMP_ENV"
        echo "   ➕ Added variable: $VAR_NAME"
        ADDED_VARS=$((ADDED_VARS + 1))
    fi
done < "$DIST_FILE"

# Append any custom variables from .env that are NOT in .env.dist
EXTRA_VARS=0
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then continue; fi
    VAR_NAME=$(echo "$line" | cut -d'=' -f1)
    if ! grep -q "^${VAR_NAME}=" "$DIST_FILE"; then
        if [ $EXTRA_VARS -eq 0 ]; then
            echo "" >> "$TEMP_ENV"
            echo "# --- Custom variables (not in .env.dist) ---" >> "$TEMP_ENV"
        fi
        echo "$line" >> "$TEMP_ENV"
        EXTRA_VARS=$((EXTRA_VARS + 1))
    fi
done < "$ENV_FILE"

cat "$TEMP_ENV" > "$ENV_FILE"
rm "$TEMP_ENV"

if [ $ADDED_VARS -gt 0 ]; then
    echo "   ✅ Added $ADDED_VARS new variables from .env.dist."
fi
if [ $EXTRA_VARS -gt 0 ]; then
    echo "   ℹ️ Preserved $EXTRA_VARS custom variables."
fi

# Load variables
set -a
source .env
set +a

# =============================================================================
# VALIDATION: Check for Critical Configuration Errors
# =============================================================================

validate_env() {
    local error_count=0

    # 1. Check DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "❌ Error: DOMAIN variable cannot be empty."
        ((error_count++))
    fi

    # 2. Check TRAEFIK_ACME_ENV_TYPE
    if [[ ! "$TRAEFIK_ACME_ENV_TYPE" =~ ^(local|staging|production)$ ]]; then
        echo "❌ Error: TRAEFIK_ACME_ENV_TYPE must be 'local', 'staging', or 'production'. Current: '$TRAEFIK_ACME_ENV_TYPE'"
        ((error_count++))
    fi

    # 3. Check ACME Email (only if not local)
    if [ "$TRAEFIK_ACME_ENV_TYPE" != "local" ]; then
        # Check for default or empty email
        if [[ "$TRAEFIK_ACME_EMAIL" == *"email@mydomain.com"* ]] || [[ "$TRAEFIK_ACME_EMAIL" == *"placeholder"* ]] || [ -z "$TRAEFIK_ACME_EMAIL" ]; then
            echo "❌ Error: TRAEFIK_ACME_EMAIL is set to default or empty, but environment is '$TRAEFIK_ACME_ENV_TYPE'."
            echo "   -> Please set a valid email in .env for Let's Encrypt notifications."
            ((error_count++))
        fi
    fi

    # 4. Check CrowdSec API Key (Deprecated - now auto-generated)
    # CROWDSEC_API_KEY is now generated automatically during the sync phase if missing.

    # 5. Check for trivial default passwords (only for staging/production)
    if [ "$TRAEFIK_ACME_ENV_TYPE" != "local" ]; then
        local trivial_passwords=0

        if [ "$DASHBOARD_ADMIN_PASSWORD" = "password" ] || [ "$DASHBOARD_ADMIN_PASSWORD" = "admin" ]; then
            echo "⚠️  Warning: DASHBOARD_ADMIN_PASSWORD is set to a trivial value."
            trivial_passwords=$((trivial_passwords + 1))
        fi
        if [ $trivial_passwords -gt 0 ]; then
            echo ""
            echo "🛑 Trivial passwords detected for a non-local environment. Please update your .env."
            exit 1
        fi
    fi

    if [ $error_count -gt 0 ]; then
        echo ""
        echo "🛑 Validation failed with $error_count errors. Please fix your .env file."
        exit 1
    fi
    echo "✅ Environment configuration valid."
}

# Run validation immediately
validate_env | sed 's/^/   /'


echo " --------------------------------------------------------"
echo " [2/6] 🔐 Synchronizing credentials & paths..."

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
}

# Dashboard Secret Key (auto-generate on first run)
if [ -z "$DASHBOARD_SECRET_KEY" ] || [ "$DASHBOARD_SECRET_KEY" == "REPLACE_ME" ]; then
    echo "   🔄 Generating Dashboard secret key..."
    NEW_DM_KEY=$(openssl rand -hex 32)
    update_env_var "DASHBOARD_SECRET_KEY" "$NEW_DM_KEY"
    export DASHBOARD_SECRET_KEY="$NEW_DM_KEY"
    set -a
    source .env
    set +a
fi

# CrowdSec Web UI Password (auto-generate on first run)
if [ -z "$CROWDSEC_WEB_UI_PASSWORD" ] || [ "$CROWDSEC_WEB_UI_PASSWORD" == "REPLACE_ME" ]; then
    echo "   🔄 Generating CrowdSec Web UI internal password..."
    NEW_CS_UI_PASS=$(openssl rand -hex 32)
    update_env_var "CROWDSEC_WEB_UI_PASSWORD" "$NEW_CS_UI_PASS"
    export CROWDSEC_WEB_UI_PASSWORD="$NEW_CS_UI_PASS"
    set -a
    source .env
    set +a
fi

# Redis Password (auto-generate on first run)
if [ -z "$REDIS_PASSWORD" ] || [ "$REDIS_PASSWORD" == "REPLACE_ME" ]; then
    echo "   🔄 Generating secure random Redis password..."
    NEW_REDIS_PASS=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)
    update_env_var "REDIS_PASSWORD" "$NEW_REDIS_PASS"
    export REDIS_PASSWORD="$NEW_REDIS_PASS"
    set -a
    source .env
    set +a
fi



# Anubis Redis Private Key (auto-generate on first run)
if [ -z "$ANUBIS_REDIS_PRIVATE_KEY" ] || [ "$ANUBIS_REDIS_PRIVATE_KEY" == "REPLACE_ME" ]; then
    echo "   🔄 Generating secure Anubis Redis private key..."
    NEW_ANUBIS_KEY=$(openssl rand -hex 32)
    update_env_var "ANUBIS_REDIS_PRIVATE_KEY" "$NEW_ANUBIS_KEY"
    export ANUBIS_REDIS_PRIVATE_KEY="$NEW_ANUBIS_KEY"
    set -a
    source .env
    set +a
fi

# CrowdSec API Key (auto-generate on first run)
if [ -z "$CROWDSEC_API_KEY" ] || [ "$CROWDSEC_API_KEY" == "REPLACE_ME" ]; then
    echo "   🔄 Generating secure CrowdSec API key..."
    NEW_CS_API_KEY=$(openssl rand -hex 32)
    update_env_var "CROWDSEC_API_KEY" "$NEW_CS_API_KEY"
    export CROWDSEC_API_KEY="$NEW_CS_API_KEY"
    set -a
    source .env
    set +a
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

# Update .env only if it's currently missing or placeholder (REPLACE_ME).
# This avoids 'path shifts' that trigger recreations when running via UI.
if [ -z "$DASHBOARD_APP_PATH_HOST" ] || [ "$DASHBOARD_APP_PATH_HOST" == "REPLACE_ME" ] || [ "$DASHBOARD_APP_PATH_HOST" == "null" ]; then
    update_env_var "DASHBOARD_APP_PATH_HOST" "$DETECTED_PATH"
    export DASHBOARD_APP_PATH_HOST="$DETECTED_PATH"
    echo "   ✅ Project path initialized: $DETECTED_PATH"
else
    # Ensure current process has the value from .env, NOT the detected path in container
    echo "   ✅ Using existing project path: $DASHBOARD_APP_PATH_HOST"
fi

# Normalize CROWDSEC_ENABLE to lowercase
CROWDSEC_ENABLE=$(echo "${CROWDSEC_ENABLE:-true}" | tr '[:upper:]' '[:lower:]')

# Normalize CROWDSEC_APPSEC_ENABLE to lowercase
CROWDSEC_APPSEC_ENABLE=$(echo "${CROWDSEC_APPSEC_ENABLE:-true}" | tr '[:upper:]' '[:lower:]')

# =============================================================================
# PHASE 2b: Generate acquis.yaml (CrowdSec log acquisition config)
# =============================================================================
# acquis.yaml is generated from acquis-base.yaml. When AppSec is enabled,
# the AppSec listener block is appended and its required collections are
# injected into COLLECTIONS so CrowdSec downloads them at startup.

ACQUIS_BASE="./config/crowdsec/acquis-base.yaml"
ACQUIS_OUT="./config/crowdsec/acquis.yaml"

if [ ! -f "$ACQUIS_BASE" ]; then
    echo "   ❌ Error: $ACQUIS_BASE not found!"
    exit 1
fi

TMP_ACQUIS=$(mktemp)
cp "$ACQUIS_BASE" "$TMP_ACQUIS"

if [[ "$CROWDSEC_ENABLE" == "true" ]] && [[ "$CROWDSEC_APPSEC_ENABLE" == "true" ]]; then
    # Append AppSec listener block
    cat >> "$TMP_ACQUIS" << 'EOF'

---

# --- AppSec (WAF) Configuration --- (auto-generated by start.sh)
appsec_configs:
  - crowdsecurity/appsec-default
labels:
  type: appsec
listen_addr: 0.0.0.0:7422
source: appsec
name: traefikAppSec
EOF

    # Inject AppSec collections into COLLECTIONS if not already present
    APPSEC_COLLECTIONS="crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
    for col in $APPSEC_COLLECTIONS; do
        if [[ "$CROWDSEC_COLLECTIONS" != *"$col"* ]]; then
            CROWDSEC_COLLECTIONS="$CROWDSEC_COLLECTIONS $col"
        fi
    done
    export CROWDSEC_COLLECTIONS

    echo "   🛡️ AppSec (WAF) is ENABLED. Collections: appsec-virtual-patching, appsec-generic-rules."
else
    echo "   ℹ️ AppSec (WAF) is DISABLED. Skipping AppSec acquis block."
fi

# Idempotent write: only update acquis.yaml if content changed
if [ -f "$ACQUIS_OUT" ] && cmp -s "$TMP_ACQUIS" "$ACQUIS_OUT"; then
    rm "$TMP_ACQUIS"
else
    cat "$TMP_ACQUIS" > "$ACQUIS_OUT"
    rm "$TMP_ACQUIS"
    echo "   ✅ acquis.yaml generated."
fi

# =============================================================================
# PHASE 2c: Generate profiles.yaml (CrowdSec remediation profiles)
# =============================================================================
# Conditionally inject CAPTCHA remediation only if fully configured.

PROFILES_BASE="./config/crowdsec/profiles-base.yaml"
PROFILES_OUT="./config/crowdsec/profiles.yaml"

if [ ! -f "$PROFILES_BASE" ]; then
    echo "   ❌ Error: $PROFILES_BASE not found!"
    exit 1
fi

TMP_PROFILES=$(mktemp)
cp "$PROFILES_BASE" "$TMP_PROFILES"

# Check if CAPTCHA registry has active configurations
HAS_ACTIVE_CAPTCHAS=false
CAPTCHA_KEYS_CSV="./config/crowdsec/captcha_keys.csv"
CAPTCHA_KEYS_DIST="./config/crowdsec/captcha_keys.csv.dist"

if [ ! -f "$CAPTCHA_KEYS_CSV" ]; then
    if [ -f "$CAPTCHA_KEYS_DIST" ]; then
        echo "   📄 Initializing captcha_keys.csv from template..."
        cp "$CAPTCHA_KEYS_DIST" "$CAPTCHA_KEYS_CSV"
    fi
fi

if [ -f "$CAPTCHA_KEYS_CSV" ]; then
    # Filter out comment lines and empty lines, check if there is at least one row containing a comma
    if grep -v -E '^(#|$|[[:space:]]*$)' "$CAPTCHA_KEYS_CSV" | grep -q ','; then
        HAS_ACTIVE_CAPTCHAS=true
    fi
fi

if [ "$HAS_ACTIVE_CAPTCHAS" = "true" ]; then
    cat >> "$TMP_PROFILES" << 'EOF'

---

# -----------------------------------------------------------------------------
# Profile 2: CAPTCHA Remediation for HTTP Scenarios (4 hours)
# -----------------------------------------------------------------------------
# HTTP-based attacks (crawlers, bad bots) get a CAPTCHA instead of a ban.
# Excludes AppSec (WAF) since those are high-confidence malicious.

name: captcha_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip" && (Alert.GetScenario() contains "http" || Alert.GetScenario() contains "traefik-flood-429") && !(Alert.GetScenario() contains "appsec")
decisions:
 - type: captcha
   duration: 4h
on_success: break
EOF
    echo "   🛡️ CAPTCHA remediation profile is ENABLED (active entries found in registry)."
else
    echo "   ℹ️ CAPTCHA registry is empty. CAPTCHA remediation is DISABLED."
fi

# Append the fallback/default aggressive bans
cat >> "$TMP_PROFILES" << 'EOF'

---

# -----------------------------------------------------------------------------
# Profile 3: Standard Aggressive Ban (24 hours)
# -----------------------------------------------------------------------------
# Default ban duration increased from 4h to 24h for all IP-based remediation.

name: aggressive_ban
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 24h   # 24 hours (default is 4h)
on_success: break

---

# -----------------------------------------------------------------------------
# Profile 4: Range-based Attacks (48 hours)
# -----------------------------------------------------------------------------
# If the attack targets a range (subnet), apply a 48-hour ban to the range.

name: range_ban
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
   duration: 48h
on_success: break
EOF

# Idempotent write: only update profiles.yaml if content changed
if [ -f "$PROFILES_OUT" ] && cmp -s "$TMP_PROFILES" "$PROFILES_OUT"; then
    rm "$TMP_PROFILES"
else
    cat "$TMP_PROFILES" > "$PROFILES_OUT"
    rm "$TMP_PROFILES"
    echo "   ✅ profiles.yaml generated."
fi

# Build Compose command with or without CrowdSec profile
# Enforce project name to avoid conflicts when running from within a container
COMPOSE_BASE="docker compose"
if [ -n "$PROJECT_NAME" ]; then
    COMPOSE_BASE="docker compose -p $PROJECT_NAME"
fi

COMPOSE_CMD="$COMPOSE_BASE"
if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
    echo "   🛡️ CrowdSec firewall is ENABLED."
else
    echo "   ⚠️ CrowdSec firewall is DISABLED."
fi


echo " --------------------------------------------------------"
echo " [3/6] 🎨 Preparing application assets..."

# =============================================================================
# Persistent data directories (bind mounts — created once, never overwritten)
# =============================================================================
# Services with non-root internal users need world-writable directories:
#   - Grafana: UID 472
#   - Loki:    UID 10001
#   - Alloy:   root (no issue)
#   - Prometheus: UID 65534 (nobody)
#   - CrowdSec: root / GID 1000 (no issue)
#   - Redis:   root (no issue)

DATA_DIRS=(
    "data/crowdsec/db"
    "data/crowdsec/config"
    "data/redis"
    "data/grafana"
    "data/loki"
    "data/alloy"
    "data/prometheus"
)
DATA_CREATED=0
for dir in "${DATA_DIRS[@]}"; do
    if [ ! -d "./$dir" ]; then
        mkdir -p "./$dir"
        DATA_CREATED=$((DATA_CREATED + 1))
    fi
done

# Ensure non-root service users can write to their data directories.
# Each service runs as a specific UID inside its container.
chown -R 472:472 ./data/grafana 2>/dev/null || chmod -R 777 ./data/grafana 2>/dev/null || true
chown -R 10001:10001 ./data/loki 2>/dev/null || chmod -R 777 ./data/loki 2>/dev/null || true
chown -R 65534:65534 ./data/prometheus 2>/dev/null || chmod -R 777 ./data/prometheus 2>/dev/null || true

if [ $DATA_CREATED -gt 0 ]; then
    echo "   ✅ Created $DATA_CREATED persistent data director(ies) under ./data/."
else
    echo "   ✅ Persistent data directories present."
fi

ANUBIS_ASSETS_DIR="./config/anubis/assets"
ANUBIS_ASSETS_IMG_DIR="$ANUBIS_ASSETS_DIR/static/img"

CUSTOM_COUNT=0
DEFAULT_COUNT=0

# CSS asset
if [ ! -f "$ANUBIS_ASSETS_DIR/custom.css" ]; then
    if [ -f "$ANUBIS_ASSETS_DIR/custom.css.dist" ]; then
        cp "$ANUBIS_ASSETS_DIR/custom.css.dist" "$ANUBIS_ASSETS_DIR/custom.css"
    fi
    DEFAULT_COUNT=$((DEFAULT_COUNT + 1))
else
    CUSTOM_COUNT=$((CUSTOM_COUNT + 1))
fi

# Image assets
for img in happy.webp pensive.webp reject.webp; do
    if [ ! -f "$ANUBIS_ASSETS_IMG_DIR/$img" ]; then
        if [ -f "$ANUBIS_ASSETS_IMG_DIR/$img.dist" ]; then
            cp "$ANUBIS_ASSETS_IMG_DIR/$img.dist" "$ANUBIS_ASSETS_IMG_DIR/$img"
        fi
        DEFAULT_COUNT=$((DEFAULT_COUNT + 1))
    else
        CUSTOM_COUNT=$((CUSTOM_COUNT + 1))
    fi
done

if [ $DEFAULT_COUNT -eq 0 ]; then
    echo "   ✅ Anubis assets ready ($CUSTOM_COUNT custom)."
elif [ $CUSTOM_COUNT -eq 0 ]; then
    echo "   ✅ Anubis assets ready ($DEFAULT_COUNT default)."
else
    echo "   ✅ Anubis assets ready ($CUSTOM_COUNT custom, $DEFAULT_COUNT default)."
fi

if [ ! -f ./config/traefik/acme.json ]; then
    touch ./config/traefik/acme.json
    chmod 600 ./config/traefik/acme.json
    echo "   ✅ Created acme.json with secure permissions."
fi

# echo "🔒 Configuring ACME environment..."
TRAEFIK_CERT_RESOLVER="le" # Default to 'le'

if [ -n "$TRAEFIK_ACME_ENV_TYPE" ]; then
    case "$TRAEFIK_ACME_ENV_TYPE" in
        staging)
            export TRAEFIK_ACME_CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
            echo "   ⚠️ Let's Encrypt STAGING environment."
            ;;
        production)
            export TRAEFIK_ACME_CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
            echo "   ✅ Let's Encrypt PRODUCTION environment."
            ;;
        local)
            export TRAEFIK_ACME_CA_SERVER="" # No CA for local
            TRAEFIK_CERT_RESOLVER=""         # Disable resolver (no 'le')
            echo "   🏠 Local Development environment (Self-Signed Certs)."
            ;;
        *)
            echo "   ⚠️ Unknown TRAEFIK_ACME_ENV_TYPE: '$TRAEFIK_ACME_ENV_TYPE'. Ignoring."
            ;;
    esac
fi

# Default to staging if TRAEFIK_ACME_CA_SERVER is still empty AND we are NOT in local mode
if [ -z "$TRAEFIK_ACME_CA_SERVER" ] && [ "$TRAEFIK_ACME_ENV_TYPE" != "local" ]; then
    export TRAEFIK_ACME_CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    echo "   ⚠️ Let's Encrypt STAGING environment (default)."
elif [ -z "$TRAEFIK_ACME_ENV_TYPE" ]; then
    # Only show this if using manual override (TRAEFIK_ACME_ENV_TYPE is empty)
    echo "   🔧 Using custom TRAEFIK_ACME_CA_SERVER from .env."
fi

# Export the resolver choice so Docker Compose can use it
export TRAEFIK_CERT_RESOLVER

# Persist to .env so container-initiated restarts (dashboard UI)
# produce identical Docker Compose config and avoid spurious recreations.
update_env_var "TRAEFIK_CERT_RESOLVER" "$TRAEFIK_CERT_RESOLVER"

# Generate traefik-generated.yaml from template (idempotent write)
echo "   ⚙️ Generating Traefik static config..."
if [ -f "./config/traefik/traefik.yaml.template" ]; then
    TMP_TRAEFIK=$(mktemp)
    sed -e "s#TRAEFIK_ACME_EMAIL_PLACEHOLDER#${TRAEFIK_ACME_EMAIL}#g" \
        -e "s#TRAEFIK_ACME_CASERVER_PLACEHOLDER#${TRAEFIK_ACME_CA_SERVER}#g" \
        -e "s#TRAEFIK_TIMEOUT_ACTIVE_PLACEHOLDER#${TRAEFIK_TIMEOUT_ACTIVE:-60}s#g" \
        -e "s#TRAEFIK_TIMEOUT_IDLE_PLACEHOLDER#${TRAEFIK_TIMEOUT_IDLE:-90}s#g" \
        -e "s#TRAEFIK_ACCESS_LOG_BUFFER_PLACEHOLDER#${TRAEFIK_ACCESS_LOG_BUFFER:-1000}#g" \
        -e "s#TRAEFIK_LOG_LEVEL_PLACEHOLDER#${TRAEFIK_LOG_LEVEL:-INFO}#g" \
        ./config/traefik/traefik.yaml.template > "$TMP_TRAEFIK"
    
    TARGET_TRAEFIK="./config/traefik/traefik-generated.yaml"
    if [ -f "$TARGET_TRAEFIK" ] && cmp -s "$TMP_TRAEFIK" "$TARGET_TRAEFIK"; then
        rm "$TMP_TRAEFIK"
    else
        cat "$TMP_TRAEFIK" > "$TARGET_TRAEFIK"
        rm "$TMP_TRAEFIK"
    fi
else
    echo "❌ Error: config/traefik/traefik.yaml.template not found!"
    exit 1
fi

# Generate redis-generated.conf from template (idempotent write)
echo "   ⚙️ Generating Redis static config..."
if [ -f "./config/redis/redis.conf" ]; then
    TMP_REDIS=$(mktemp)
    sed "s#REDIS_PASSWORD_PLACEHOLDER#${REDIS_PASSWORD}#g" \
        ./config/redis/redis.conf > "$TMP_REDIS"
    
    TARGET_REDIS="./config/redis/redis-generated.conf"
    if [ -f "$TARGET_REDIS" ] && cmp -s "$TMP_REDIS" "$TARGET_REDIS"; then
        rm "$TMP_REDIS"
    else
        cat "$TMP_REDIS" > "$TARGET_REDIS"
        rm "$TMP_REDIS"
    fi
else
    echo "❌ Error: config/redis/redis.conf not found!"
    exit 1
fi



# Generate dynamic configuration with Python script
{
    mkdir -p ./config/traefik/dynamic-config
    mkdir -p ./config/anubis
} || {
    echo "❌ Error: Could not clean up generated files due to permissions."
    echo "   This usually happens if Docker created the directories as root."
    echo "   Please run: sudo chown -R $(id -u):$(id -g) ."
    exit 1
}

# Safety check: if docker-compose-anubis-generated.yaml is a directory (Docker artifact), try to remove it
if [ -d "docker-compose-anubis-generated.yaml" ]; then
    echo "⚠️ Cleaning up directory collision: docker-compose-anubis-generated.yaml"
    rm -rf docker-compose-anubis-generated.yaml || echo "   ⚠️  Warning: Could not remove directory 'docker-compose-anubis-generated.yaml'. If it's a mount point, this is expected."
else
    echo "   ✅ docker-compose-anubis-generated.yaml directory check passed."
fi

# Safety check: if domains.csv is a directory (Docker artifact), remove it
if [ -d "domains.csv" ]; then
    echo "⚠️ Cleaning up directory collision: domains.csv"
    rm -rf domains.csv
fi

# Ensure domains.csv exists with correct header
if [ ! -f "domains.csv" ]; then
    echo "   📄 Creating default domains.csv..."
    echo "# domain, redirection, service, anubis_subdomain, rate, burst, concurrency" > domains.csv
fi

# Determine Python interpreter
if [ -f ".venv/bin/python3" ]; then
    PYTHON_CMD=".venv/bin/python3"
elif [ -f "venv/bin/python3" ]; then
    PYTHON_CMD="venv/bin/python3"
else
    PYTHON_CMD="python3"
fi

# Check dependencies before running
if ! $PYTHON_CMD -c "import tldextract; import yaml" >/dev/null 2>&1; then
    echo "❌ Error: Python dependencies missing (tldextract, pyyaml)."
    echo "   👉 Please run 'make init' to set up the environment."
    exit 1
fi

$PYTHON_CMD scripts/generate-config.py | sed 's/^/   /'


# Fix permissions if running internally (files created as root)
if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
    echo "   🔧 Internal run detected. Fixing permissions for generated files..."
    # We try to match the parent directory's ownership if possible, or just ensure readability
    # Ideally we would know the host UID/GID, but making them world-readable (644) for config files is usually safe enough for Traefik to read.
    # config/traefik/dynamic-config is mounted ro in Traefik, but Traefik needs to read it.
    
    # Robust permission fix: Directories 755, Files 644
    find ./config/traefik -type d -exec chmod 755 {} \;
    find ./config/traefik -type f -name "*.yaml" -exec chmod 644 {} \;
    find ./config/traefik -type f -name "*.json" -exec chmod 600 {} \; # acme.json needs 600
    chmod 644 ./domains.csv
    if [ -f "./config/crowdsec/captcha_keys.csv" ]; then
        chmod 640 ./config/crowdsec/captcha_keys.csv  # 640: owner rw, group r — not world-writable
    fi
    
    # Ensure acme.json is strictly 600 (override the find above if needed, though find catches json)
    # But acme.json should NOT be world readable? Traefik generally wants 600.
    # If find set it to 644 (if ended in yaml?), no. acme.json ends in json.
    # We explicitly force acme.json to 600 just in case.
    if [ -f "./config/traefik/acme.json" ]; then
        chmod 600 ./config/traefik/acme.json
    fi
    
    # Match ownership to parent directory (host user)
    # Linux stat uses -c, macOS uses -f; try Linux first.
    TARGET_UID=$(stat -c '%u' ./config/traefik 2>/dev/null) || TARGET_UID=$(stat -f '%u' ./config/traefik 2>/dev/null) || TARGET_UID=""
    TARGET_GID=$(stat -c '%g' ./config/traefik 2>/dev/null) || TARGET_GID=$(stat -f '%g' ./config/traefik 2>/dev/null) || TARGET_GID=""
    
    if [ -n "$TARGET_UID" ] && [ -n "$TARGET_GID" ]; then
         chown -R "$TARGET_UID:$TARGET_GID" ./config/traefik/dynamic-config
         chown "$TARGET_UID:$TARGET_GID" ./domains.csv
         if [ -f "./config/crowdsec/captcha_keys.csv" ]; then
             chown "$TARGET_UID:$TARGET_GID" ./config/crowdsec/captcha_keys.csv
         fi
         echo "      ✅ Ownership fixed to $TARGET_UID:$TARGET_GID"
    else
         echo "      ⚠️  Could not determine target ownership. Left as root but readable."
    fi
fi



# =============================================================================
# PHASE 3: Local SSL Trust (mkcert)
# =============================================================================
# If local certificates are found AND we are in local mode, configure Traefik to use them.

if [ "$TRAEFIK_ACME_ENV_TYPE" == "local" ]; then
    echo "   🔐 Local Mode detected. Automating certificate generation..."
    # If running internally (inside container), skip generation to preserve host trust.
    # If certs are missing, FAIL and tell the user to run them on the host.
    if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
        CERTS_DIR="./config/traefik/certs-local-dev" # Define CERTS_DIR here for internal check
        if [ -f "$CERTS_DIR/local-cert.pem" ]; then
            echo "   ℹ️ Certificates already exist. Skipping internal generation to preserve host trust."
        else
            echo "   ❌ ERROR: Local certificates not found in $CERTS_DIR."
            echo "   👉 Please run 'make certs-create-local' on your host first."
            exit 1
        fi
    else
        if [ -f "./scripts/create-local-certs.sh" ]; then
            [ -w "./scripts/create-local-certs.sh" ] && chmod +x ./scripts/create-local-certs.sh
            ./scripts/create-local-certs.sh
        else
            echo "   ⚠️ Warning: ./scripts/create-local-certs.sh not found. Skipping auto-generation."
        fi
    fi

    echo "   🔐 Checking for local trusted certificates (Local Mode)..."
    CERTS_DIR="./config/traefik/certs-local-dev"
    TRAEFIK_CERTS_CONF="./config/traefik/dynamic-config/local-certs.yaml"

    if [ -f "$CERTS_DIR/local-cert.pem" ] && [ -f "$CERTS_DIR/local-key.pem" ]; then
        echo "   📋 Local certificates found. Configuring Traefik to use them..."
        cat > "$TRAEFIK_CERTS_CONF" << EOF
# AUTOMATICALLY GENERATED - Local SSL Trust
tls:
  certificates:
    - certFile: /certs/local-cert.pem
      keyFile: /certs/local-key.pem
  stores:
    default:
      defaultCertificate:
        certFile: /certs/local-cert.pem
        keyFile: /certs/local-key.pem
EOF
        echo "   ✅ Generated local-certs.yaml."
    else
        echo "   ℹ️ No custom local certificates found."
        if [ -f "$TRAEFIK_CERTS_CONF" ]; then
            rm "$TRAEFIK_CERTS_CONF"
            echo "   🗑️  Removed stale local-certs.yaml."
        fi
    fi
fi


echo " --------------------------------------------------------"
echo " [4/6] 🌐 Preparing network & security layer..."
WHITELIST_FILE="./config/crowdsec/parsers/ip-whitelist.yaml"

if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
    
    # Initialize lists with default internal ranges
    declare -a IPS_LIST=("127.0.0.1")
    declare -a CIDRS_LIST=("172.16.0.0/12" "10.0.0.0/8" "192.168.0.0/16")
    
    # Add custom entries from .env if present
    CUSTOM_ENTRY_COUNT=0
    if [ -n "$CROWDSEC_WHITELIST_IPS" ]; then
        IFS=',' read -ra ENTRIES <<< "$CROWDSEC_WHITELIST_IPS"
        for entry in "${ENTRIES[@]}"; do
            entry=$(echo "$entry" | xargs) # Trim
            if [ -n "$entry" ]; then
                if [[ "$entry" == *"/"* ]]; then
                    CIDRS_LIST+=("$entry")
                    CUSTOM_ENTRY_COUNT=$((CUSTOM_ENTRY_COUNT + 1))
                else
                    IPS_LIST+=("$entry")
                    CUSTOM_ENTRY_COUNT=$((CUSTOM_ENTRY_COUNT + 1))
                fi
            fi
        done
    fi

    # Build the YAML whitelist file in a temporary location
    TMP_WHITELIST=$(mktemp)
    
    cat > "$TMP_WHITELIST" << 'EOF'
# ============================================================================
# CrowdSec IP Whitelist - Auto-generated
# ============================================================================
# This file includes internal network ranges and custom IPs from .env
# ============================================================================

name: custom/ip-whitelist
description: "Internal network ranges and user-defined trusted IPs"
whitelist:
  reason: "Internal network or configured via CROWDSEC_WHITELIST_IPS"
EOF

    # Write IP section
    if [ ${#IPS_LIST[@]} -gt 0 ]; then
        echo "  ip:" >> "$TMP_WHITELIST"
        for ip in "${IPS_LIST[@]}"; do
            echo "    - \"$ip\"" >> "$TMP_WHITELIST"
        done
    fi

    # Write CIDR section
    if [ ${#CIDRS_LIST[@]} -gt 0 ]; then
        echo "  cidr:" >> "$TMP_WHITELIST"
        for cidr in "${CIDRS_LIST[@]}"; do
            echo "    - \"$cidr\"" >> "$TMP_WHITELIST"
        done
    fi

    # Only overwrite the real file if content changed
    if [ -f "$WHITELIST_FILE" ] && cmp -s "$TMP_WHITELIST" "$WHITELIST_FILE"; then
        rm "$TMP_WHITELIST"
    else
        cat "$TMP_WHITELIST" > "$WHITELIST_FILE"
        rm "$TMP_WHITELIST"
    fi
    
    TOTAL_ENTRIES=$((${#IPS_LIST[@]} + ${#CIDRS_LIST[@]}))
    if [ $CUSTOM_ENTRY_COUNT -gt 0 ]; then
        echo "   ✅ CrowdSec whitelist: $TOTAL_ENTRIES entries ($CUSTOM_ENTRY_COUNT custom)."
    else
        echo "   ✅ CrowdSec whitelist: $TOTAL_ENTRIES entries."
    fi
else
    echo "   ℹ️ CrowdSec is disabled, skipping whitelist generation."
    # Remove old whitelist if it exists to avoid stale entries
    if [ -f "$WHITELIST_FILE" ]; then
        rm -f "$WHITELIST_FILE"
        echo "   🗑️ Removed old whitelist file."
    fi
fi

# =============================================================================
# PHASE 4: User-Agent Blacklist Configuration
# =============================================================================
# This variable is used by generate-config.py to create native Traefik blocking rules.
if [ -n "$TRAEFIK_BAD_USER_AGENTS" ]; then
    UA_COUNT=$(echo "$TRAEFIK_BAD_USER_AGENTS" | tr ',' '\n' | grep -c .)
    echo "   🛡️ UA blacklist: $UA_COUNT patterns configured."
    export TRAEFIK_BAD_USER_AGENTS
fi


if ! docker network inspect anubis-backend >/dev/null 2>&1; then
    docker network create --internal anubis-backend
    echo "   ✅ Created anubis-backend network (internal)."
fi

if ! docker network inspect traefik >/dev/null 2>&1; then
    docker network create traefik
    echo "   ✅ Created traefik network."
fi

# =============================================================================
# PHASE 4: Build Compose File List
# =============================================================================

# --- Apache Detection ---
# Probe port 8080 on the host — the only source of truth.
# Avoids dpkg-query (Debian-only, detects installed-but-STOPPED Apache) and
# flag files / env-var propagation headaches.
# When running on the host:      target = localhost
# When running in a container:   target = APACHE_HOST_IP (docker0 gateway, default 172.17.0.1)
APACHE_FLAG_FILE=".apache_host_available"
APACHE_CHECK_PORT="${APACHE_HOST_PORT:-8080}"

if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
    APACHE_CHECK_HOST="${APACHE_HOST_IP:-172.17.0.1}"
else
    APACHE_CHECK_HOST="localhost"
fi

if python3 -c "import socket; s = socket.socket(); s.settimeout(1); exit(0) if s.connect_ex(('${APACHE_CHECK_HOST}', int('${APACHE_CHECK_PORT}'))) == 0 else exit(1)" 2>/dev/null; then
    export APACHE_HOST_AVAILABLE="true"
    touch "$APACHE_FLAG_FILE"
else
    export APACHE_HOST_AVAILABLE="false"
    rm -f "$APACHE_FLAG_FILE"
fi

# --- Build compose file list (shared with stop.sh and Makefile) ---
source scripts/compose-files.sh

if [ "$APACHE_HOST_AVAILABLE" == "true" ]; then
    echo "   📋 Apache legacy detected, including logs extension."
fi


echo " --------------------------------------------------------"
echo " [5/6] 👮 Booting security layer..."

if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
    # Smart check: Is it already running and healthy?
    CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
    CS_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CROWDSEC_ID" 2>/dev/null || echo "none")

    if [ "$CS_STATUS" == "healthy" ]; then
        echo "   🛡️ CrowdSec is already operational. Applying any config changes..."
        $COMPOSE_CMD $COMPOSE_FILES up -d crowdsec
        sleep 1 # Allow time for recreation if compose detected a change

        # Refresh ID — container may have been recreated due to config changes
        CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)

        # Wait for healthy in case of recreation
        timeout=60
        while [ -z "$CROWDSEC_ID" ] || [ "$(docker inspect --format='{{.State.Health.Status}}' $CROWDSEC_ID 2>/dev/null)" != "healthy" ]; do
            sleep 2
            echo -n "."
            ((timeout-=2))
            if [ $timeout -le 0 ]; then
                echo ""
                echo "   ❌ Timeout waiting for CrowdSec to become healthy after config update."
                exit 1
            fi
            CROWDSEC_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=crowdsec | head -n 1)
        done
    else
        echo "   🛡 Booting CrowdSec + Redis..."
        $COMPOSE_CMD $COMPOSE_FILES up -d crowdsec redis
        sleep 1 # Allow terminal to settle

        # Wait for CrowdSec to be healthy
        echo -n "   ⏳ Waiting for CrowdSec API"
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
        echo "   ✅ CrowdSec operational."
    fi

    # =============================================================================
    # PHASE 5: Register Bouncer API Key
    # =============================================================================
    # Re-register the Traefik Bouncer key on each start to ensure consistency.
    # Delete first (silently) in case it already exists, then add fresh.

    docker exec "$CROWDSEC_ID" cscli bouncers delete traefik-bouncer > /dev/null 2>&1 || true
    ADD_OUTPUT=$(docker exec "$CROWDSEC_ID" cscli bouncers add traefik-bouncer --key "${CROWDSEC_API_KEY}" 2>&1)
    ADD_EXIT=$?

    if [ $ADD_EXIT -eq 0 ]; then
        echo "   🔑 Bouncer key registered."
    else
        echo "❌ Error registering bouncer key: $ADD_OUTPUT"
        exit 1
    fi

    # =============================================================================
    # PHASE 5: Register Web UI Machine
    # =============================================================================
    # Register the Web UI machine to allow it to communicate with LAPI.
    # We use -f /dev/null to avoid overwriting the local credentials of the crowdsec container itself.
    
    echo "   🛡️ Hardening CrowdSec LAPI (trusted_ips)..."
    # Use |= ... | unique instead of += to avoid duplicating entries on each start.
    # += always appends, so running 'make start' N times would grow the array N times.
    docker exec "$CROWDSEC_ID" sh -c "yq -i '.api.server.trusted_ips |= (. + [\"172.16.0.0/12\", \"192.168.0.0/16\"] | unique)' /etc/crowdsec/config.yaml"
    docker exec "$CROWDSEC_ID" kill -HUP 1

    echo "   🖥️ Registering CrowdSec Web UI machine..."
    docker exec "$CROWDSEC_ID" cscli machines delete "${CROWDSEC_WEB_UI_USER:-crowdsec-web-ui}" > /dev/null 2>&1 || true
    docker exec "$CROWDSEC_ID" cscli machines add "${CROWDSEC_WEB_UI_USER:-crowdsec-web-ui}" --password "${CROWDSEC_WEB_UI_PASSWORD}" -f /dev/null > /dev/null 2>&1 || true
    echo "   ✅ Web UI machine registered."

    # =============================================================================
    # PHASE 5: CrowdSec Console Enrollment (Optional)
    # =============================================================================
    # If CROWDSEC_ENROLLMENT_KEY is set, enroll this instance with CrowdSec Console
    # for access to community blocklists and centralized management.

    if [ -n "$CROWDSEC_ENROLLMENT_KEY" ] && [ "$CROWDSEC_ENROLLMENT_KEY" != "REPLACE_ME" ]; then
        echo "   🌐 Enrolling CrowdSec to Console..."
        if docker exec "$CROWDSEC_ID" cscli console enroll "$CROWDSEC_ENROLLMENT_KEY" --name "$(hostname)" 2>/dev/null; then
            echo "   ✅ Successfully enrolled in CrowdSec Console."
        else
            echo "   ⚠️ Console enrollment failed or already enrolled. Continuing..."
        fi
    fi
else
    REDIS_ID=$(docker ps -aq --filter label=com.docker.compose.project=$PROJECT_NAME --filter label=com.docker.compose.service=redis | head -n 1)
    if [ -n "$REDIS_ID" ] && [ "$(docker inspect --format='{{.State.Running}}' $REDIS_ID 2>/dev/null)" == "true" ]; then
        echo "   🛡️ Redis is already operational. Skipping boot."
    else
        echo "   🛡️ Booting Redis (CrowdSec is disabled)..."
        $COMPOSE_CMD $COMPOSE_FILES up -d redis
        sleep 1
        echo "   ✅ Redis operational."
    fi
fi

# =============================================================================
# PHASE 6: Deploy Remaining Services
# =============================================================================
# Now that the security layer is ready, deploy everything else.
# --remove-orphans cleans up any old containers not in current config.


echo " --------------------------------------------------------"
# If running inside dashboard, we perform a 'Config Audit' first to detect shifts.
if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
    echo "   🔍 Auditing docker-compose configuration for drift..."
    # This helps us see which variables are causing recreations in the modal log
    $COMPOSE_CMD $COMPOSE_FILES config --quiet || echo "      ⚠️ Warning: Config validation failed."
fi

# Deploy everything.
$COMPOSE_CMD $COMPOSE_FILES up -d --remove-orphans
sleep 1

echo "   🔍 Verifying Core DNS records..."
CORE_SUBS=("dashboard")
MISSING_DNS=()

# Helper for DNS resolution (cross-platform)
resolve_host() {
    local host="$1"
    
    # 0. Check /etc/hosts first (Reliable for local dev, respects $HOSTS_FILE)
    if grep -qE "[[:space:]]${host}([[:space:]]|$)" "$HOSTS_FILE"; then
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
        ping -c 1 -t 1 "$host" >/dev/null 2>&1 || ping -c 1 -W 1 "$host" >/dev/null 2>&1
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
# DONE
# =============================================================================

# ⏲️ Calculate Duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "========================================================"
echo "✅ DEPLOYMENT COMPLETE! (Total time: ${DURATION}s)"
echo "========================================================"
echo ""
echo "🌐 Core Services:"
    echo -e "   ➜ Dashboard Home:  https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/"
    echo -e "   ➜ Domain Manager:  https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/domains"
    echo -e "   ➜ CAPTCHA Keys:    https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/captchas"
    echo -e "   ➜ Certificates:    https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/certs"
    echo -e "   ➜ Traefik:         https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/traefik/"
    echo -e "   ➜ Dozzle (Logs):   https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/dozzle/"
    echo -e "   ➜ Grafana:         https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/grafana/"
    if [[ "$CROWDSEC_ENABLE" == "true" ]]; then
        echo -e "   ➜ CrowdSec UI:     https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/crowdsec/"
    else
        echo -e "   ➜ CrowdSec UI:     [DISABLED] (CROWDSEC_ENABLE=false)"
    fi
    echo -e "========================================================"
echo ""
