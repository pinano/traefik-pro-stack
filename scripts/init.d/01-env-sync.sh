#!/bin/bash

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
echo ""
echo "── [1/6] 📋 Preparing environment ──────────────────────────────────────"
# Safely create backup with 600 permissions
rm -f "${ENV_FILE}.bak"
(umask 077 && cp "$ENV_FILE" "${ENV_FILE}.bak")
TEMP_ENV=$(mktemp)
ADDED_VARS=0

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
    if awk -F= -v var="$VAR_NAME" '$1 == var { found=1; exit } END { exit !found }' "$ENV_FILE"; then
        # Use existing value from .env (take the first occurrence)
        awk -F= -v var="$VAR_NAME" '$1 == var { print; exit }' "$ENV_FILE" >> "$TEMP_ENV"
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
    if ! awk -F= -v var="$VAR_NAME" '$1 == var { found=1; exit } END { exit !found }' "$DIST_FILE"; then
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
chmod 600 "$ENV_FILE"

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

    # 4. Check CrowdSec Local API Key (Deprecated - now auto-generated)
    # CROWDSEC_LAPI_KEY is now generated automatically during the sync phase if missing.

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

# Run validation immediately in the parent shell to properly handle failures (exit codes).
# Use a temporary file to keep the indented output without running in a subshell pipeline.
VAL_OUT=$(mktemp)
validate_env > "$VAL_OUT" 2>&1
VAL_STATUS=$?
sed 's/^/   /' "$VAL_OUT"
rm -f "$VAL_OUT"
if [ $VAL_STATUS -ne 0 ]; then
    exit 1
fi

