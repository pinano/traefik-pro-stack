#!/bin/bash

# =============================================================================
# PHASE 3: Local SSL Trust (mkcert)
# =============================================================================
# If local certificates are found AND we are in local mode, configure Traefik to use them.

if [ "$TRAEFIK_ACME_ENV_TYPE" == "local" ]; then
    CERTS_DIR="./config/traefik/certs-local-dev"
    TRAEFIK_CERTS_CONF="./config/traefik/dynamic-config/local-certs.yaml"

    # Check if certs exist, if not generate or error out
    if [ ! -f "$CERTS_DIR/local-cert.pem" ] || [ ! -f "$CERTS_DIR/local-key.pem" ]; then
        if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
            echo "   ❌ ERROR: Local certificates not found in $CERTS_DIR."
            echo "   👉 Please run 'make certs-create-local' on your host first."
            exit 1
        else
            if [ -f "./scripts/create-local-certs.sh" ]; then
                [ -w "./scripts/create-local-certs.sh" ] && chmod +x ./scripts/create-local-certs.sh
                ./scripts/create-local-certs.sh
            else
                echo "   ⚠️ Warning: ./scripts/create-local-certs.sh not found. Skipping auto-generation."
            fi
        fi
    fi

    # Configure Traefik to use them (if they exist)
    if [ -f "$CERTS_DIR/local-cert.pem" ] && [ -f "$CERTS_DIR/local-key.pem" ]; then
        # Generate local-certs.yaml if missing
        if [ ! -f "$TRAEFIK_CERTS_CONF" ]; then
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
        fi
    else
        echo "   ℹ️ No custom local certificates found."
        if [ -f "$TRAEFIK_CERTS_CONF" ]; then
            rm "$TRAEFIK_CERTS_CONF"
            echo "   🗑️  Removed stale local-certs.yaml."
        fi
    fi
fi


echo ""
echo "── [4/6] 🌐 Preparing network & security layer ─────────────────────────"
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

