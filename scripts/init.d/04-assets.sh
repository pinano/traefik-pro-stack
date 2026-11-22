#!/bin/bash

ENV_FILE="${ENV_FILE:-.env}"

if ! command -v update_env_var &>/dev/null; then
    update_env_var() {
        local var_name=$1
        local new_val=$2
        local current_val=$(awk -F= -v name="$var_name" '$1 == name { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]*["\x27]?|["\x27]?[[:space:]]*$/, ""); print; exit }' "$ENV_FILE")
        if [ "$current_val" = "$new_val" ]; then return; fi
        if [[ "$new_val" =~ [[:space:]] ]] && [[ ! "$new_val" =~ ^\".*\"$ ]] && [[ ! "$new_val" =~ ^\'.*\'$ ]]; then
            new_val="\"$new_val\""
        fi
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
fi

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
# When directories are newly created, set permissions recursively.
# On subsequent starts, only touch the directory root to avoid slow disk traversal of large TSDB/log volumes.
# Prometheus runs as HOST_UID:HOST_GID (docker-compose-observability.yaml),
# so its data dir must be owned by the operator, not by a fixed container uid.
OPERATOR_UID=$(stat -c '%u' ./config/traefik 2>/dev/null || stat -f '%u' ./config/traefik 2>/dev/null || echo 1000)
OPERATOR_GID=$(stat -c '%g' ./config/traefik 2>/dev/null || stat -f '%g' ./config/traefik 2>/dev/null || echo 1000)
if [ $DATA_CREATED -gt 0 ]; then
    chown -R 472:472 ./data/grafana 2>/dev/null || chmod -R 777 ./data/grafana 2>/dev/null || true
    chown -R 10001:10001 ./data/loki 2>/dev/null || chmod -R 777 ./data/loki 2>/dev/null || true
    chown -R "$OPERATOR_UID:$OPERATOR_GID" ./data/prometheus 2>/dev/null || chmod -R 777 ./data/prometheus 2>/dev/null || true
    chown -R 1000:1000 ./data/filebrowser 2>/dev/null || chmod -R 777 ./data/filebrowser 2>/dev/null || true
    echo "   ✅ Created $DATA_CREATED persistent data director(ies) under ./data/."
else
    chown 472:472 ./data/grafana 2>/dev/null || chmod 777 ./data/grafana 2>/dev/null || true
    chown 10001:10001 ./data/loki 2>/dev/null || chmod 777 ./data/loki 2>/dev/null || true
    chown "$OPERATOR_UID:$OPERATOR_GID" ./data/prometheus 2>/dev/null || chmod 777 ./data/prometheus 2>/dev/null || true
    chown 1000:1000 ./data/filebrowser 2>/dev/null || chmod 777 ./data/filebrowser 2>/dev/null || true
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

mkdir -p ./config/traefik

# Safety check: if acme.json is a directory (Docker artifact from bind-mount before file existed), remove it
if [ -d ./config/traefik/acme.json ]; then
    echo "⚠️ Cleaning up directory collision: ./config/traefik/acme.json (created by Docker)"
    rm -rf ./config/traefik/acme.json || {
        echo "❌ Error: Could not remove directory './config/traefik/acme.json'."
        echo "   Please run: sudo rm -rf ./config/traefik/acme.json && sudo chown -R \$(id -u):\$(id -g) ."
        exit 1
    }
fi

if [ ! -f ./config/traefik/acme.json ]; then
    touch ./config/traefik/acme.json || {
        echo "❌ Error: Cannot create ./config/traefik/acme.json due to permissions."
        echo "   Please run: sudo chown -R \$(id -u):\$(id -g) ."
        exit 1
    }
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
    # Atomic write (audit M2): stage in the target directory (same filesystem)
    # and rename, so a crash can never leave a truncated config behind.
    TMP_TRAEFIK=$(mktemp ./config/traefik/.traefik-generated.yaml.XXXXXX)
    python3 -c '
import os, sys
template_path = "./config/traefik/traefik.yaml.template"
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()

trusted_ips_raw = os.getenv("TRAEFIK_TRUSTED_IPS", "").strip()
forwarded_block = ""
if trusted_ips_raw:
    quote_chars = chr(34) + chr(39)
    ips = [ip.strip().strip(quote_chars) for ip in trusted_ips_raw.split(",") if ip.strip().strip(quote_chars)]
    if ips:
        lines = ["    forwardedHeaders:", "      trustedIPs:"]
        for ip in ips:
            lines.append("        - \"" + ip + "\"")
        forwarded_block = "\n".join(lines)

replacements = {
    "TRAEFIK_ACME_EMAIL_PLACEHOLDER": os.getenv("TRAEFIK_ACME_EMAIL", ""),
    "TRAEFIK_ACME_CASERVER_PLACEHOLDER": os.getenv("TRAEFIK_ACME_CA_SERVER", ""),
    "TRAEFIK_TIMEOUT_ACTIVE_PLACEHOLDER": os.getenv("TRAEFIK_TIMEOUT_ACTIVE", "60") + "s",
    "TRAEFIK_TIMEOUT_IDLE_PLACEHOLDER": os.getenv("TRAEFIK_TIMEOUT_IDLE", "90") + "s",
    "TRAEFIK_ACCESS_LOG_BUFFER_PLACEHOLDER": os.getenv("TRAEFIK_ACCESS_LOG_BUFFER", "1000"),
    "TRAEFIK_LOG_LEVEL_PLACEHOLDER": os.getenv("TRAEFIK_LOG_LEVEL", "INFO"),
    "TRAEFIK_FORWARDED_HEADERS_WEB_PLACEHOLDER": forwarded_block,
    "TRAEFIK_FORWARDED_HEADERS_WEBSECURE_PLACEHOLDER": forwarded_block
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
        mv -f "$TMP_TRAEFIK" "$TARGET_TRAEFIK"
    fi
else
    echo "❌ Error: config/traefik/traefik.yaml.template not found!"
    exit 1
fi


# Generate valkey-generated.conf from template (idempotent write)
if [ -f "./config/valkey/valkey.conf" ]; then
    # Atomic write (audit M2): stage next to the target, then rename.
    TMP_VALKEY=$(mktemp ./config/valkey/.valkey-generated.conf.XXXXXX)
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
        mv -f "$TMP_VALKEY" "$TARGET_VALKEY"
    fi
    # This file embeds REDIS_PASSWORD — restrict to owner (600). The container
    # runs as the operator uid (HOST_UID, synced by 01-env-sync.sh), which can
    # read its own files.
    chmod 600 "$TARGET_VALKEY" 2>/dev/null || true
    # When the operator is root, the valkey image entrypoint re-executes the
    # server as its internal valkey user (uid 999) via setpriv, so the config
    # must be readable by that uid — still 600, just owned by 999:1000.
    if [ "$(id -u)" = "0" ]; then
        chown 999:1000 "$TARGET_VALKEY" 2>/dev/null || true
    fi

# Generate CrowdSec config.yaml.local from template (idempotent write)
if [ -f "./config/crowdsec/config.yaml.local.template" ]; then
    # Atomic write (audit M2): stage next to the target, then rename.
    TMP_CS_CONF=$(mktemp ./config/crowdsec/.config.yaml.local.XXXXXX)
    python3 -c '
import os, sys
with open("./config/crowdsec/config.yaml.local.template", "r", encoding="utf-8") as f:
    content = f.read()
replacements = {
    "CROWDSEC_DB_USER_PLACEHOLDER": os.getenv("CROWDSEC_DB_USER", "crowdsec").replace(chr(34), "\\\""),
    "CROWDSEC_DB_PASSWORD_PLACEHOLDER": os.getenv("CROWDSEC_DB_PASSWORD", "").replace(chr(34), "\\\""),
    "CROWDSEC_DB_NAME_PLACEHOLDER": os.getenv("CROWDSEC_DB_NAME", "crowdsec").replace(chr(34), "\\\"")
}
for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(content)
' "$TMP_CS_CONF"

    TARGET_CS_CONF="./config/crowdsec/config.yaml.local"
    if [ -f "$TARGET_CS_CONF" ] && cmp -s "$TMP_CS_CONF" "$TARGET_CS_CONF"; then
        rm "$TMP_CS_CONF"
    else
        mv -f "$TMP_CS_CONF" "$TARGET_CS_CONF"
    fi
    # This file embeds CROWDSEC_DB_PASSWORD — restrict to owner (CrowdSec runs
    # as uid/gid 1000, matching the host owner, so 600 is safe).
    chmod 600 "$TARGET_CS_CONF" 2>/dev/null || true
fi
else
    echo "❌ Error: config/valkey/valkey.conf not found!"
    exit 1
fi

# Generate Prometheus web auth config (audit M7): bcrypt hash of the
# remote-write token so Prometheus itself rejects unauthenticated writers
# (previously only Alloy sent a bearer token; the server accepted anything).
if [ -f "./config/prometheus/web.yml.template" ]; then
    HASHING_PY=""
    for PY_CANDIDATE in "./.venv/bin/python3" "python3"; do
        if "$PY_CANDIDATE" -c "import bcrypt" 2>/dev/null; then
            HASHING_PY="$PY_CANDIDATE"
            break
        fi
    done
    if [ -z "$HASHING_PY" ]; then
        echo "❌ Error: bcrypt module not available (run 'make init' to install Python deps)."
        echo "   Refusing to boot without server-side remote-write authentication for Prometheus."
        exit 1
    fi

    if [ -z "${PROMETHEUS_REMOTE_WRITE_TOKEN:-}" ]; then
        echo "⚠️  Warning: PROMETHEUS_REMOTE_WRITE_TOKEN is empty — remote-write auth will be unusable."
    fi

    mkdir -p ./config/prometheus
    TMP_WEB=$(mktemp ./config/prometheus/.web-generated.yml.XXXXXX)
    "$HASHING_PY" -c '
import bcrypt, os, sys
token = os.getenv("PROMETHEUS_REMOTE_WRITE_TOKEN", "").encode()
hashed = bcrypt.hashpw(token, bcrypt.gensalt(rounds=10)).decode()
with open("./config/prometheus/web.yml.template", "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("PROMETHEUS_REMOTE_WRITE_TOKEN_BCRYPT_PLACEHOLDER", hashed)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(content)
' "$TMP_WEB" || { echo "❌ Error: could not hash PROMETHEUS_REMOTE_WRITE_TOKEN"; rm -f "$TMP_WEB"; exit 1; }

    TARGET_WEB="./config/prometheus/web-generated.yml"
    if [ -f "$TARGET_WEB" ] && cmp -s "$TMP_WEB" "$TARGET_WEB"; then
        rm "$TMP_WEB"
    else
        mv -f "$TMP_WEB" "$TARGET_WEB"
    fi
    # The bcrypt hash lets an attacker brute-force the token offline.
    chmod 600 "$TARGET_WEB" 2>/dev/null || true

    # Plaintext token for authenticated *clients* (Prometheus self-scrape and
    # its healthcheck). Client-side secrets are plaintext by design; the file
    # is owner-only.
    TOKEN_FILE="./config/prometheus/remote-write-token"
    TMP_TOKEN=$(mktemp ./config/prometheus/.remote-write-token.XXXXXX)
    printf '%s\n' "${PROMETHEUS_REMOTE_WRITE_TOKEN:-}" > "$TMP_TOKEN"
    if [ -f "$TOKEN_FILE" ] && cmp -s "$TMP_TOKEN" "$TOKEN_FILE"; then
        rm "$TMP_TOKEN"
    else
        mv -f "$TMP_TOKEN" "$TOKEN_FILE"
    fi
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
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

# User-Agent Blacklist Configuration
if [ -n "$TRAEFIK_BAD_USER_AGENTS" ]; then
    UA_COUNT=$(echo "$TRAEFIK_BAD_USER_AGENTS" | tr ',' '\n' | grep -c .)
    echo "   🛡️ UA blacklist: $UA_COUNT pattern(s) configured."
    export TRAEFIK_BAD_USER_AGENTS
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
    chmod 644 ./config/crowdsec/*.yaml 2>/dev/null || true
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
         if [ -f "./config/crowdsec/profiles.yaml" ]; then
             chown "$TARGET_UID:$TARGET_GID" ./config/crowdsec/profiles.yaml 2>/dev/null || true
         fi
         if [ -f "./config/crowdsec/acquis.yaml" ]; then
             chown "$TARGET_UID:$TARGET_GID" ./config/crowdsec/acquis.yaml 2>/dev/null || true
         fi
    else
         echo "      ⚠️  Could not determine target ownership. Left as root but readable."
    fi
fi
