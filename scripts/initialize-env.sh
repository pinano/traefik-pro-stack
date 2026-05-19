#!/bin/bash

# initialize_env.sh
# Automates the setup of the .env file from .env.dist

set -e

# =============================================================================
# TERMINAL RESTORATION
# =============================================================================

cleanup() {
    set +e
    if [ -t 0 ]; then
        tput cnorm 2>/dev/null || true
        stty echo 2>/dev/null || true
    fi
    return 0
}

trap cleanup EXIT INT TERM

DIST_FILE=".env.dist"
ENV_FILE=".env"

# ASCII Art / Header
echo "========================================================"
echo "      🤖 TRAEFIK + CROWDSEC + ANUBIS SETUP 🤖            "
echo "========================================================"

# ==============================================================================
# PYTHON ENVIRONMENT SETUP
# ==============================================================================
echo "🐍 Checking Python environment..."

# Check if python3 is installed
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: python3 is not installed."
    exit 1
fi

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "📦 Creating virtual environment (.venv)..."
    python3 -m venv .venv
fi

# Install requirements
# Install requirements
if [ -f "scripts/requirements.txt" ]; then
    echo "⬇️  Installing/Updating Python dependencies..."
    ./.venv/bin/pip install -q -r scripts/requirements.txt || echo "⚠️  Warning: Failed to install dependencies. Check your internet connection."
else
    echo "⚠️  Warning: scripts/requirements.txt not found. Skipping dependency installation."
fi

echo "✅ Python environment ready."
echo ""

# 1. File Setup
if [ ! -f "$DIST_FILE" ]; then
    echo "❌ Error: $DIST_FILE not found."
    exit 1
fi

if [ -f "$ENV_FILE" ]; then
    echo "⚠️  $ENV_FILE already exists."
    read -p "   Overwrite it? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "   Aborted."
        exit 0
    fi
    cp "$ENV_FILE" "${ENV_FILE}.save"
    echo "   Backup created at ${ENV_FILE}.save"
fi

echo "📋 Copying $DIST_FILE to $ENV_FILE..."
cp "$DIST_FILE" "$ENV_FILE"

# Helper function to prompt and replace
# usage: prompt_val VAR_NAME DESCRIPTION
prompt_val() {
    local var_name=$1
    local desc=$2
    # Grep the current value from the file (handles defaults from dist)
    local current_val
    current_val=$(grep "^${var_name}=" "$ENV_FILE" | cut -d'=' -f2-)
    
    # Remove single quotes if present for display
    local display_val="${current_val//\'/}"

    echo ""
    echo "👉 $desc"
    read -p "   Enter value [${display_val}]: " input_val

    if [ -n "$input_val" ]; then
        # Use a temporary file and awk + ENVIRON for a truly literal replacement.
        # This handles ALL special characters (\, |, &, quotes) without delimiter hell.
        local TMP_FILE=$(mktemp)
        NEW_VAL="$input_val" awk -v name="$var_name" '
            BEGIN { FS="="; val=ENVIRON["NEW_VAL"]; found=0 }
            $1 == name { print name "=" val; found=1; next }
            { print }
            END { if (found == 0) print name "=" val }
        ' "$ENV_FILE" > "$TMP_FILE"
        cat "$TMP_FILE" > "$ENV_FILE"
        rm "$TMP_FILE"
        echo "   ✅ Set to: $input_val"
    else
        echo "   ⏭️ Keeping default: $display_val"
    fi
}

# Helper to blindly replace without prompt
replace_val() {
    local var_name=$1
    local new_val=$2
    # Use a temporary file and awk + ENVIRON for a truly literal replacement.
    local TMP_FILE=$(mktemp)
    NEW_VAL="$new_val" awk -v name="$var_name" '
        BEGIN { FS="="; val=ENVIRON["NEW_VAL"]; found=0 }
        $1 == name { print name "=" val; found=1; next }
        { print }
        END { if (found == 0) print name "=" val }
    ' "$ENV_FILE" > "$TMP_FILE"
    cat "$TMP_FILE" > "$ENV_FILE"
    rm "$TMP_FILE"
}

echo ""
echo "🔧 CONFIGURING VARIABLES..."


# --- INTERACTIVE PROMPTS ---

prompt_val "DOMAIN" "Core domain (e.g. example.com)"
prompt_val "PROJECT_NAME" "Docker Compose Project Name (prefix for containers)"
prompt_val "TZ" "Timezone (e.g. Europe/Madrid)"
prompt_val "TRAEFIK_ACME_EMAIL" "Let's Encrypt email"
prompt_val "TRAEFIK_LISTEN_IP" "Traefik Listen IP (default: 0.0.0.0 for all)"
prompt_val "TRAEFIK_ACME_ENV_TYPE" "ACME Environment (production/staging/local)"

prompt_val "ANUBIS_DIFFICULTY" "Anubis challenge difficulty (1-5)"
prompt_val "ANUBIS_CPU_LIMIT" "Anubis CPU limit per instance"
prompt_val "ANUBIS_MEM_LIMIT" "Anubis memory limit per instance"

# REDIS_PASSWORD: Offer random generation
echo ""
read -p "👉 Generate random REDIS_PASSWORD (20 chars)? (Y/n): " gen_redis
if [[ "$gen_redis" == "y" || "$gen_redis" == "Y" || -z "$gen_redis" ]]; then
    # Generate 20 chars, alphanumeric
    NEW_REDIS_PASS=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)
    replace_val "REDIS_PASSWORD" "$NEW_REDIS_PASS"
    echo "   ✅ Generated REDIS_PASSWORD: $NEW_REDIS_PASS"
else
    prompt_val "REDIS_PASSWORD" "Redis Password (manual input)"
fi

prompt_val "DASHBOARD_SUBDOMAIN" "Dashboard Subdomain (e.g. 'dashboard' for dashboard.example.com)"

prompt_val "CROWDSEC_UPDATE_INTERVAL" "CrowdSec update interval (seconds)"

echo ""
read -p "👉 Disable CrowdSec Firewall completely? (y/N): " disable_cs
if [[ "$disable_cs" == "y" || "$disable_cs" == "Y" ]]; then
    replace_val "CROWDSEC_ENABLE" "false"
    echo "   ✅ CrowdSec DISABLED"
else
    replace_val "CROWDSEC_ENABLE" "true"
    echo "   ✅ CrowdSec ENABLED"
fi

echo ""
echo "👉 CrowdSec Console Enrollment (optional)"
echo "   Get your key from https://app.crowdsec.net"
read -p "   Enter enrollment key (leave empty to skip): " cs_enroll_key
if [ -n "$cs_enroll_key" ]; then
    replace_val "CROWDSEC_ENROLLMENT_KEY" "$cs_enroll_key"
    echo "   ✅ Set CROWDSEC_ENROLLMENT_KEY"
else
    echo "   ⏭️ Skipping console enrollment"
fi

echo ""
echo "👉 CrowdSec Collections (scenarios/parsers)"
echo "   Remove 'crowdsecurity/http-dos' if you get too many false positives"
echo "   ⚠️  If you modify this on an existing installation, you may need to reset CrowdSec volumes:"
echo "      docker volume rm \$(docker volume ls -q | grep crowdsec)"
prompt_val "CROWDSEC_COLLECTIONS" "CrowdSec collections to load (space-separated)"

echo ""
echo "👉 CrowdSec IP Whitelist (optional)"
echo "   Enter IPs/CIDRs to bypass CrowdSec detection (comma-separated)"
echo "   Example: 192.168.1.1,10.0.0.0/8"
prompt_val "CROWDSEC_WHITELIST_IPS" "CrowdSec whitelist IPs (leave empty for none)"

prompt_val "TRAEFIK_GLOBAL_RATE_AVG" "Traefik default rate limit (requests/sec)"
prompt_val "TRAEFIK_GLOBAL_RATE_BURST" "Traefik default burst limit"
prompt_val "TRAEFIK_GLOBAL_CONCURRENCY" "Traefik global concurrency"
prompt_val "TRAEFIK_TIMEOUT_ACTIVE" "Traefik active timeout (read/write/header) in seconds"
prompt_val "TRAEFIK_TIMEOUT_IDLE" "Traefik idle timeout in seconds"
prompt_val "TRAEFIK_BLOCKED_PATHS" "Global Blocked Paths (e.g. /wp-admin/,/admin/)"
prompt_val "TRAEFIK_BAD_USER_AGENTS" "Bad User Agents (regex, comma-separated)"
prompt_val "TRAEFIK_GOOD_USER_AGENTS" "Good User Agents (regex, comma-separated)"
prompt_val "TRAEFIK_ACCESS_LOG_BUFFER" "Access Log Buffer Size"
prompt_val "TRAEFIK_LOG_LEVEL" "Traefik Log Level (DEBUG/INFO/WARN/ERROR)"
prompt_val "TRAEFIK_HSTS_MAX_AGE" "HSTS max age (seconds)"
prompt_val "TRAEFIK_FRAME_ANCESTORS" "Allowed Iframe Ancestors (e.g. https://my-other-web.com)"

# --- DASHBOARD CREDENTIALS (SSO) ---
echo ""
echo "👉 Dashboard Admin Credentials (SSO for all services)"
read -p "   User [admin]: " dm_user
[ -z "$dm_user" ] && dm_user="admin"
replace_val "DASHBOARD_ADMIN_USER" "$dm_user"

read -p "   Password [password]: " dm_pass
[ -z "$dm_pass" ] && dm_pass="password"
replace_val "DASHBOARD_ADMIN_PASSWORD" "$dm_pass"

# --- GRAFANA ADMIN CREDENTIALS ---
echo ""
echo "👉 Grafana Admin Credentials (for full admin access inside Grafana)"
echo "   Press Enter to use the same as Dashboard credentials ($dm_user / $dm_pass)"
read -p "   Grafana Admin User [$dm_user]: " gf_user
[ -z "$gf_user" ] && gf_user="$dm_user"
replace_val "GRAFANA_ADMIN_USER" "$gf_user"

read -p "   Grafana Admin Password [$dm_pass]: " gf_pass
[ -z "$gf_pass" ] && gf_pass="$dm_pass"
replace_val "GRAFANA_ADMIN_PASSWORD" "$gf_pass"

prompt_val "WATCHDOG_TELEGRAM_BOT_TOKEN" "Telegram Bot Token (for Let's Encrypt renewal alerts)"
prompt_val "WATCHDOG_TELEGRAM_RECIPIENT_ID" "Telegram Chat/Group ID (for Let's Encrypt renewal alerts)"
prompt_val "WATCHDOG_CERT_DAYS_WARNING" "Days before SSL certificate expiration to send alert (default: 10)"
prompt_val "WATCHDOG_CROWDSEC_CHECK_INTERVAL" "CrowdSec Watchdog check interval (seconds)"
prompt_val "WATCHDOG_DNS_CHECK_INTERVAL" "DNS check interval (seconds)"

# --- AUTOMATED GENERATION ---

echo ""
echo "🔐 GENERATING SECURITY KEYS..."

# 1. ANUBIS_REDIS_PRIVATE_KEY
read -p "👉 Generate new Anubis Redis private key with openssl? (Y/n): " gen_anubis
if [[ "$gen_anubis" == "y" || "$gen_anubis" == "Y" || -z "$gen_anubis" ]]; then
    NEW_KEY=$(openssl rand -hex 32)
    replace_val "ANUBIS_REDIS_PRIVATE_KEY" "$NEW_KEY"
    echo "   ✅ Generated ANUBIS_REDIS_PRIVATE_KEY"
fi

# 1B. DASHBOARD_SECRET_KEY
DM_KEY=$(grep "^DASHBOARD_SECRET_KEY=" "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$DM_KEY" ] || [ "$DM_KEY" == "REPLACE_ME" ]; then
    echo "🔐 Generating secure random Secret Key for Dashboard..."
    NEW_DM_KEY=$(openssl rand -hex 32)
    replace_val "DASHBOARD_SECRET_KEY" "$NEW_DM_KEY"
    echo "   ✅ Generated DASHBOARD_SECRET_KEY"
else
    echo ""
    echo "👉 Dashboard Secret Key is already set."
    read -p "   Regenerate it? (y/N): " regen_dm_key
    if [[ "$regen_dm_key" == "y" || "$regen_dm_key" == "Y" ]]; then
        NEW_DM_KEY=$(openssl rand -hex 32)
        replace_val "DASHBOARD_SECRET_KEY" "$NEW_DM_KEY"
        echo "   ✅ Re-generated DASHBOARD_SECRET_KEY"
    fi
fi


# 3. CROWDSEC_API_KEY
ENABLE_CS=$(grep "^CROWDSEC_ENABLE=" "$ENV_FILE" | cut -d'=' -f2-)
if [[ "$ENABLE_CS" != "false" ]]; then
    echo ""
    read -p "👉 Generate NEW CrowdSec API Key (requires starting docker)? (y/N): " gen_cs
    if [[ "$gen_cs" == "y" || "$gen_cs" == "Y" ]]; then
    # Ensure network exists
    if ! docker network inspect traefik >/dev/null 2>&1; then
        echo "   🌐 Creating required 'traefik' network..."
        docker network create traefik
    fi

    COMPOSE_FILE="docker-compose-security.yaml"
    echo "   🚀 Starting CrowdSec container..."
    docker compose -f $COMPOSE_FILE up -d crowdsec
    
    echo "   ⏳ Waiting for CrowdSec API..."
    # Wait loop
    timeout=60
    while true; do
        CS_CID=$(docker compose -f $COMPOSE_FILE ps -q crowdsec 2>/dev/null || true)
        if [ -n "$CS_CID" ] && [ "$(docker inspect --format='{{.State.Health.Status}}' $CS_CID 2>/dev/null)" == "healthy" ]; then
            break
        fi
        
        sleep 2
        echo -n "."
        ((timeout-=2))
        if [ $timeout -le 0 ]; then
             echo "   ❌ Timeout waiting for CrowdSec."
             break
        fi
    done
    echo ""

    CS_CID=$(docker compose -f $COMPOSE_FILE ps -q crowdsec 2>/dev/null || true)
    if [ -n "$CS_CID" ] && [ "$(docker inspect --format='{{.State.Health.Status}}' $CS_CID 2>/dev/null)" == "healthy" ]; then
        echo "   🔑 Generating CROWDSEC_API_KEY..."
        # First remove old one if exists to avoid error
        docker compose -f $COMPOSE_FILE exec -T crowdsec cscli bouncers delete traefik-bouncer >/dev/null 2>&1 || true
        # Add new one and capture output
        CS_KEY=$(docker compose -f $COMPOSE_FILE exec -T crowdsec cscli bouncers add traefik-bouncer -o raw)
        
        if [ -n "$CS_KEY" ]; then
            replace_val "CROWDSEC_API_KEY" "$CS_KEY"
            echo "   ✅ Generated and saved CROWDSEC_API_KEY"
        else
            echo "   ❌ Failed to retrieve key from cscli."
        fi
    fi

    echo "   🛑 Stopping CrowdSec..."
    docker compose -f docker-compose-security.yaml stop crowdsec
    fi
else
    echo ""
    echo "   ⏭️ Skipping CrowdSec API Key generation (CrowdSec is disabled)."
fi

echo ""
echo "========================================================"
echo "✅ SETUP COMPLETE! settings saved to $ENV_FILE"
echo "========================================================"
