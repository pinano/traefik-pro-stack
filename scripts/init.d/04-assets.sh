#!/bin/bash

echo ""
echo "── [3/6] 🎨 Preparing application assets ───────────────────────────────"

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
    "data/grafana"
    "data/loki"
    "data/alloy"
    "data/prometheus"
    "data/filebrowser"
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
chown -R 1000:1000 ./data/filebrowser 2>/dev/null || chmod -R 777 ./data/filebrowser 2>/dev/null || true

if [ $DATA_CREATED -gt 0 ]; then
    echo "   ✅ Created $DATA_CREATED persistent data director(ies) under ./data/."
fi

ANUBIS_ASSETS_DIR="./config/anubis/assets"
ANUBIS_ASSETS_IMG_DIR="$ANUBIS_ASSETS_DIR/static/img"

# CSS asset
if [ ! -f "$ANUBIS_ASSETS_DIR/custom.css" ]; then
    if [ -f "$ANUBIS_ASSETS_DIR/custom.css.dist" ]; then
        cp "$ANUBIS_ASSETS_DIR/custom.css.dist" "$ANUBIS_ASSETS_DIR/custom.css"
    fi
fi

# Image assets
for img in happy.webp pensive.webp reject.webp; do
    if [ ! -f "$ANUBIS_ASSETS_IMG_DIR/$img" ]; then
        if [ -f "$ANUBIS_ASSETS_IMG_DIR/$img.dist" ]; then
            cp "$ANUBIS_ASSETS_IMG_DIR/$img.dist" "$ANUBIS_ASSETS_IMG_DIR/$img"
        fi
    fi
done

if [ ! -f ./config/traefik/acme.json ]; then
    touch ./config/traefik/acme.json
    chmod 600 ./config/traefik/acme.json
    echo "   ✅ Created acme.json with secure permissions."
fi

if [ -f ./config/crowdsec/captcha_keys.csv ]; then
    chmod 600 ./config/crowdsec/captcha_keys.csv 2>/dev/null || true
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
if [ -f "./config/traefik/traefik.yaml.template" ]; then
    TMP_TRAEFIK=$(mktemp)
    python3 -c '
import os, sys
template_path = "./config/traefik/traefik.yaml.template"
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()
replacements = {
    "TRAEFIK_ACME_EMAIL_PLACEHOLDER": os.getenv("TRAEFIK_ACME_EMAIL", ""),
    "TRAEFIK_ACME_CASERVER_PLACEHOLDER": os.getenv("TRAEFIK_ACME_CA_SERVER", ""),
    "TRAEFIK_TIMEOUT_ACTIVE_PLACEHOLDER": os.getenv("TRAEFIK_TIMEOUT_ACTIVE", "60") + "s",
    "TRAEFIK_TIMEOUT_IDLE_PLACEHOLDER": os.getenv("TRAEFIK_TIMEOUT_IDLE", "90") + "s",
    "TRAEFIK_ACCESS_LOG_BUFFER_PLACEHOLDER": os.getenv("TRAEFIK_ACCESS_LOG_BUFFER", "1000"),
    "TRAEFIK_LOG_LEVEL_PLACEHOLDER": os.getenv("TRAEFIK_LOG_LEVEL", "INFO")
}
for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(content)
' "$TMP_TRAEFIK"
    
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

# Generate valkey-generated.conf from template (idempotent write)
if [ -f "./config/valkey/valkey.conf" ]; then
    TMP_VALKEY=$(mktemp)
    python3 -c '
import os, sys
with open("./config/valkey/valkey.conf", "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("REDIS_PASSWORD_PLACEHOLDER", os.getenv("REDIS_PASSWORD", ""))
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(content)
' "$TMP_VALKEY"
    
    TARGET_VALKEY="./config/valkey/valkey-generated.conf"
    if [ -f "$TARGET_VALKEY" ] && cmp -s "$TMP_VALKEY" "$TARGET_VALKEY"; then
        rm "$TMP_VALKEY"
    else
        cat "$TMP_VALKEY" > "$TARGET_VALKEY"
        rm "$TMP_VALKEY"
    fi
else
    echo "❌ Error: config/valkey/valkey.conf not found!"
    exit 1
fi

# Generate dynamic configuration with Python script
{
    mkdir -p ./config/traefik/dynamic-config
    mkdir -p ./config/anubis
} || {
    echo "❌ Error: Could not clean up generated files due to permissions."
    echo "   This usually happens if Docker created the directories as root."
    echo "   Please run: sudo chown -R \$(id -u):\$(id -g) ."
    exit 1
}

# Safety check: if docker-compose-anubis-generated.yaml is a directory (Docker artifact), try to remove it
if [ -d "docker-compose-anubis-generated.yaml" ]; then
    echo "⚠️ Cleaning up directory collision: docker-compose-anubis-generated.yaml"
    rm -rf docker-compose-anubis-generated.yaml || echo "   ⚠️  Warning: Could not remove directory 'docker-compose-anubis-generated.yaml'. If it's a mount point, this is expected."
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
        chmod 600 ./config/crowdsec/captcha_keys.csv  # 600: owner rw only
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
    else
         echo "      ⚠️  Could not determine target ownership. Left as root but readable."
    fi
fi
