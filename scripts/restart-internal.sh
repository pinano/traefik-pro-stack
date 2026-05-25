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

echo ""
echo "========================================================"
echo "🔄 APPLYING CONFIGURATION CHANGES..."
echo "========================================================"
echo ""

# ─── Step 1: Regenerate Config ──────────────────────────────────
echo " --------------------------------------------------------"
echo " [1/3] 🎨 Regenerating configuration..."

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

$PYTHON_CMD scripts/generate-config.py | sed 's/^/   /'

# ─── Step 2: Fix Permissions ────────────────────────────────────
echo " --------------------------------------------------------"
echo " [2/3] 🔧 Fixing permissions..."

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
    echo "   ✅ Ownership fixed to $TARGET_UID:$TARGET_GID"
else
    echo "   ⚠️ Could not determine target ownership. Files left as-is."
fi

# ─── Step 3: Apply Changes ──────────────────────────────────────
echo " --------------------------------------------------------"
echo " [3/3] 🚀 Applying changes to the stack..."

# Build compose file list (same logic as compose-files.sh)
source scripts/compose-files.sh

# Build compose command with explicit project name
COMPOSE_CMD="docker compose -p ${PROJECT_NAME:-stack}"
if [[ "${CROWDSEC_ENABLE:-true}" == "true" ]]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile crowdsec"
fi

# Audit config for drift (helpful for debugging in modal log)
echo "   🔍 Validating compose configuration..."
$COMPOSE_CMD $COMPOSE_FILES config --quiet 2>&1 || echo "   ⚠️ Warning: Config validation produced warnings."

# Apply changes with --no-recreate:
#   - Creates NEW containers (new Anubis instances from updated compose)
#   - Removes ORPHANED containers (deleted Anubis instances)
#   - Does NOT touch existing containers (avoids env drift recreation)
#
# Routing changes are picked up by Traefik's file watcher automatically.
# ACME certs for new domains are requested by Traefik when it sees a new
# router with certResolver=le in the dynamic config.
echo "   🚀 Running docker compose up -d --no-recreate..."
$COMPOSE_CMD $COMPOSE_FILES up -d --no-recreate --remove-orphans 2>&1 | sed 's/^/   /'

echo ""
echo "========================================================"
echo "✅ CONFIGURATION APPLIED SUCCESSFULLY"
echo "========================================================"
echo ""
