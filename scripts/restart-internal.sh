#!/bin/bash

# =============================================================================
# restart-internal.sh - Targeted Stack Restart for Dashboard UI
# =============================================================================
# A lightweight restart that regenerates config and applies changes
# WITHOUT recreating existing containers.
#
# Designed to run INSIDE the dashboard container.
#
# Strategy:
#   1. Regenerate dynamic config (Traefik routes, Anubis compose, policies)
#   2. Fix file permissions (container runs as root)
#   3. Use `docker compose up -d --no-recreate --remove-orphans` to:
#      - Create NEW containers (e.g., new Anubis instances)
#      - Remove ORPHANED containers (e.g., deleted Anubis instances)
#      - Leave EXISTING containers untouched (no environment drift risk)
#
# Traefik picks up routing changes via its built-in file watcher — no
# container restart needed for new/changed domains. ACME certificates
# for new domains are requested automatically by Traefik when it detects
# a new router with certResolver=le.
#
# This replaces the previous approach of calling the full start.sh,
# which caused Docker Compose environment drift and recreated all
# containers on every restart from the UI.
# =============================================================================

set -e

# Suppress LibreSSL warnings on macOS (urllib3 v2 compatibility)
export PYTHONWARNINGS="ignore:urllib3 v2 only supports"
export PYTHONUNBUFFERED=1

# ─── Mutex: Prevent concurrent executions ────────────────────────
LOCKFILE="/tmp/stack-restart.lock"
if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        echo "⚠️ Another stack restart process is already running. Skipping concurrent execution."
        exit 0
    fi
else
    LOCKDIR="/tmp/stack-restart.lockdir"
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        echo "⚠️ Another stack restart process is already running. Skipping concurrent execution."
        exit 0
    fi
    trap 'rm -rf "$LOCKDIR"' EXIT INT TERM
fi

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "🔄 APPLYING CONFIGURATION CHANGES..."
echo "────────────────────────────────────────────────────────────────────────"
echo ""

# ─── Step 1: Regenerate Config ──────────────────────────────────
echo "─── [1/3] 🎨 Regenerating configuration ────────────────────────────────"

# Safety checks (same as start.sh)
if [ -d "docker-compose-anubis-generated.yaml" ]; then
    echo "   ⚠️ Cleaning up directory collision: docker-compose-anubis-generated.yaml"
    rm -rf docker-compose-anubis-generated.yaml
fi

if [ -d "domains.csv" ]; then
    echo "   ⚠️ Cleaning up directory collision: domains.csv"
    rm -rf domains.csv
fi

mkdir -p ./config/traefik/dynamic-config
mkdir -p ./config/anubis

# Ensure domains.csv exists
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

$PYTHON_CMD scripts/generate-config.py | sed -u 's/^/   /'

# ─── Step 1b: Regenerate CrowdSec profiles.yaml ─────────────────
# profiles.yaml depends on captcha_keys.csv (managed from the Captchas UI).
# If the CAPTCHA config changed, regenerate the file and reload CrowdSec
# (SIGHUP triggers a profiles reload in CrowdSec v1.x without container restart).

PROFILES_BASE="./config/crowdsec/profiles-base.yaml"
PROFILES_OUT="./config/crowdsec/profiles.yaml"
CAPTCHA_KEYS_CSV="./config/crowdsec/captcha_keys.csv"

if [ -f "$PROFILES_BASE" ]; then
    TMP_PROFILES=$(mktemp)
    cp "$PROFILES_BASE" "$TMP_PROFILES"

    # Inject CAPTCHA profile if captcha_keys.csv has active entries
    if [ -f "$CAPTCHA_KEYS_CSV" ] && grep -v -E '^(#|$|[[:space:]]*$)' "$CAPTCHA_KEYS_CSV" | grep -q ','; then
        cat >> "$TMP_PROFILES" << 'CAPTCHA_EOF'

---

# -----------------------------------------------------------------------------
# Profile 2: CAPTCHA Remediation for HTTP Scenarios (4 hours)
# -----------------------------------------------------------------------------
name: captcha_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip" && (Alert.GetScenario() contains "http" || Alert.GetScenario() contains "traefik-flood-429") && !(Alert.GetScenario() contains "appsec")
decisions:
 - type: captcha
   duration: 4h
on_success: break
CAPTCHA_EOF
    fi

    cat >> "$TMP_PROFILES" << 'FALLBACK_EOF'

---

# -----------------------------------------------------------------------------
# Profile 3: Standard Aggressive Ban (24 hours)
# -----------------------------------------------------------------------------
name: aggressive_ban
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 24h
on_success: break

---

# -----------------------------------------------------------------------------
# Profile 4: Range-based Attacks (48 hours)
# -----------------------------------------------------------------------------
name: range_ban
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
   duration: 48h
on_success: break
FALLBACK_EOF

    if [ -f "$PROFILES_OUT" ] && cmp -s "$TMP_PROFILES" "$PROFILES_OUT"; then
        rm "$TMP_PROFILES"
        echo "   ✔ profiles.yaml unchanged — no CrowdSec reload needed."
    else
        cat "$TMP_PROFILES" > "$PROFILES_OUT"
        rm "$TMP_PROFILES"
        echo "   🔄 profiles.yaml updated."

        # Reload CrowdSec if it's running (SIGHUP reloads profiles without restart)
        if [ "${CROWDSEC_ENABLE:-true}" = "true" ]; then
            CS_ID=$(docker ps -q --filter "label=com.docker.compose.project=${PROJECT_NAME:-stack}" --filter "label=com.docker.compose.service=crowdsec" 2>/dev/null | head -n 1)
            if [ -n "$CS_ID" ]; then
                docker exec "$CS_ID" kill -HUP 1 > /dev/null 2>&1 && \
                    echo "   ✔ CrowdSec reloaded (SIGHUP) to apply new profiles." || \
                    echo "   ⚠️  Could not send SIGHUP to CrowdSec. Run 'make restart crowdsec' to apply CAPTCHA profile changes."
            fi
        fi
    fi
fi


# ─── Step 2: Fix Permissions ────────────────────────────────────
echo "─── [2/3] 🔧 Fixing permissions ────────────────────────────────────────"

# Robust permission fix: Directories 755, Files 644
find ./config/traefik -type d -exec chmod 755 {} \;
find ./config/traefik -type f -name "*.yaml" -exec chmod 644 {} \;
find ./config/traefik -type f -name "*.json" -exec chmod 600 {} \;
chmod 644 ./domains.csv 2>/dev/null || true

# Ensure docker-compose-anubis-generated.yaml is readable
if [ -f "docker-compose-anubis-generated.yaml" ]; then
    chmod 644 docker-compose-anubis-generated.yaml
fi

# Ensure anubis policy is readable
if [ -f "./config/anubis/botPolicy-generated.yaml" ]; then
    chmod 644 ./config/anubis/botPolicy-generated.yaml
fi

# Ensure captcha_keys.csv has secure permissions
if [ -f "./config/crowdsec/captcha_keys.csv" ]; then
    chmod 600 ./config/crowdsec/captcha_keys.csv
fi

# Match ownership to parent directory (host user)
# Linux stat uses -c, macOS uses -f; try Linux first.
TARGET_UID=$(stat -c '%u' ./config/traefik 2>/dev/null) || TARGET_UID=$(stat -f '%u' ./config/traefik 2>/dev/null) || TARGET_UID=""
TARGET_GID=$(stat -c '%g' ./config/traefik 2>/dev/null) || TARGET_GID=$(stat -f '%g' ./config/traefik 2>/dev/null) || TARGET_GID=""

if [ -n "$TARGET_UID" ] && [ -n "$TARGET_GID" ]; then
    chown -R "$TARGET_UID:$TARGET_GID" ./config/traefik/dynamic-config 2>/dev/null || true
    chown "$TARGET_UID:$TARGET_GID" ./domains.csv 2>/dev/null || true
    if [ -f "docker-compose-anubis-generated.yaml" ]; then
        chown "$TARGET_UID:$TARGET_GID" docker-compose-anubis-generated.yaml 2>/dev/null || true
    fi
    if [ -f "./config/anubis/botPolicy-generated.yaml" ]; then
        chown "$TARGET_UID:$TARGET_GID" ./config/anubis/botPolicy-generated.yaml 2>/dev/null || true
    fi
    if [ -f "./config/crowdsec/captcha_keys.csv" ]; then
        chown "$TARGET_UID:$TARGET_GID" ./config/crowdsec/captcha_keys.csv 2>/dev/null || true
    fi
else
    echo "   ⚠️ Could not determine target ownership. Files left as-is."
fi

# ─── Step 3: Apply Changes ──────────────────────────────────────
echo "─── [3/3] 🚀 Applying changes to the stack ─────────────────────────────"

# --- Apache Detection ---
# Probe port 8080 on the host — the only source of truth.
APACHE_FLAG_FILE=".apache_host_available"
APACHE_CHECK_PORT="${APACHE_HOST_PORT:-8080}"

if [ -f /.dockerenv ] || [ "${DASHBOARD_INTERNAL:-}" == "true" ]; then
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

# Build compose file list (same logic as compose-files.sh)
source scripts/compose-files.sh

# Build compose command with explicit project name
COMPOSE_CMD="docker compose -p ${PROJECT_NAME:-stack}"
if [[ "${CROWDSEC_ENABLE:-true}" == "true" ]]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile crowdsec"
fi

# Audit config for drift (helpful for debugging in modal log)
$COMPOSE_CMD $COMPOSE_FILES config --quiet || echo "   ⚠️ Warning: Config validation produced warnings."

# Apply changes with --no-recreate:
#   - Creates NEW containers (new Anubis instances from updated compose)
#   - Removes ORPHANED containers (deleted Anubis instances)
#   - Does NOT touch existing containers (avoids env drift recreation)
#
# Routing changes are picked up by Traefik's file watcher automatically.
# ACME certs for new domains are requested by Traefik when it sees a new
# router with certResolver=le in the dynamic config.
$COMPOSE_CMD --progress quiet $COMPOSE_FILES up -d --no-recreate --remove-orphans > /dev/null
echo "   ✅ Stack configuration up-to-date."

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "✅ CONFIGURATION APPLIED SUCCESSFULLY"
echo "────────────────────────────────────────────────────────────────────────"
echo ""
