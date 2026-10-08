#!/bin/bash

# Ensures .env exists and is up to date with .env.dist structure.

DIST_FILE=".env.dist"
ENV_FILE=".env"

JUST_INITIALIZED=0

# 1. Check if .env exists, if not, initialize
if [ ! -f "$ENV_FILE" ]; then
    echo "⚠️  $ENV_FILE not found. Running initialization..."
    if [ -f "./scripts/initialize-env.sh" ]; then
        [ -w "./scripts/initialize-env.sh" ] && chmod +x ./scripts/initialize-env.sh
        ./scripts/initialize-env.sh
        JUST_INITIALIZED=1
    else
        echo "❌ Error: initialize-env.sh not found. Please create $ENV_FILE manually."
        exit 1
    fi
fi

# 1. Environment Preparation
echo ""
echo "── [1/6] 📋 Preparing environment ──────────────────────────────────────"

if [ "$JUST_INITIALIZED" -eq 1 ]; then
    echo "   ✅ Environment freshly initialized and synchronized."
else
    # Safely create backup with 600 permissions
    rm -f "${ENV_FILE}.bak"
    (umask 077 && cp "$ENV_FILE" "${ENV_FILE}.bak")
    TEMP_ENV=$(mktemp)

    # Perform instant single-pass structure synchronization
    SYNC_STATS=$(python3 -c '
import sys
import platform
dist_file = sys.argv[1]
env_file = sys.argv[2]
out_file = sys.argv[3]
is_darwin = platform.system() == "Darwin"

env_vars = {}
with open(env_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        s = line.strip()
        if s and not s.startswith("#") and "=" in line:
            k = line.split("=", 1)[0].strip()
            if k not in env_vars:
                env_vars[k] = line.rstrip("\r\n")

dist_keys = set()
added_count = 0
output_lines = []

with open(dist_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in line:
            output_lines.append(line.rstrip("\r\n"))
            continue
        k = line.split("=", 1)[0].strip()
        dist_keys.add(k)
        if k in env_vars:
            output_lines.append(env_vars[k])
        else:
            line_to_add = line.rstrip("\r\n")
            if is_darwin:
                if k == "CROWDSEC_ENABLE":
                    line_to_add = "CROWDSEC_ENABLE=false"
                elif k == "BACKREST_ENABLE":
                    line_to_add = "BACKREST_ENABLE=false"
            output_lines.append(line_to_add)
            added_count += 1

extra_lines = []
with open(env_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        s = line.strip()
        if s and not s.startswith("#") and "=" in line:
            k = line.split("=", 1)[0].strip()
            if k not in dist_keys:
                extra_lines.append(line.rstrip("\r\n"))

if extra_lines:
    output_lines.append("")
    output_lines.append("# --- Custom variables (not in .env.dist) ---")
    output_lines.extend(extra_lines)

with open(out_file, "w", encoding="utf-8") as f:
    f.write("\n".join(output_lines) + "\n")

print(f"{added_count} {len(extra_lines)}")
' "$DIST_FILE" "$ENV_FILE" "$TEMP_ENV")

    ADDED_VARS=$(echo "$SYNC_STATS" | awk '{print $1}')
    EXTRA_VARS=$(echo "$SYNC_STATS" | awk '{print $2}')

    if cmp -s "$TEMP_ENV" "$ENV_FILE"; then
        rm "$TEMP_ENV"
    else
        cat "$TEMP_ENV" > "$ENV_FILE"
        rm "$TEMP_ENV"
        chmod 600 "$ENV_FILE"
    fi

    if [ "$ADDED_VARS" -gt 0 ]; then
        echo "   ✅ Added $ADDED_VARS new variables from .env.dist."
    fi
    if [ "$EXTRA_VARS" -gt 0 ]; then
        echo "   ℹ️ Preserved $EXTRA_VARS custom variables."
    fi
fi

# Load variables
set -a
source ./.env
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

