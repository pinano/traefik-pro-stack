#!/bin/bash

# Script to generate local SSL certificates for local development (mkcert)

# Directory where certs should be stored (relative to project root)
CERT_DIR="config/traefik/certs-local-dev"

# Ensure output directory exists
mkdir -p "$CERT_DIR"

# Load environment if present
if [ -f .env ]; then
    set -a
    source ./.env
    set +a
elif [ -f ../.env ]; then
    set -a
    source ../.env
    set +a
fi

# Determine which hosts file to use (support for running inside dashboard container)
HOSTS_FILE="/etc/hosts"
if [ -f "/etc/hosts-host" ]; then
    HOSTS_FILE="/etc/hosts-host"
fi

# Collect all relevant local domains:
# 1. Base local defaults
ALL_DOMAINS="localhost *.localhost 127.0.0.1 ::1"

# 2. Project core domain & dashboard
CORE_DOMAIN="${DOMAIN:-localhost}"
ALL_DOMAINS="$ALL_DOMAINS $CORE_DOMAIN *.$CORE_DOMAIN ${DASHBOARD_SUBDOMAIN:-dashboard}.$CORE_DOMAIN"

# 3. Domains from domains.csv (if exists)
if [ -f "domains.csv" ]; then
    CSV_DOMAINS=$(awk -F',' '!/^#/ && NF > 0 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 != "") print $1 }' domains.csv 2>/dev/null | tr '\n' ' ')
    ALL_DOMAINS="$ALL_DOMAINS $CSV_DOMAINS"
fi

# 4. Hostnames pointing to 127.0.0.1 in hosts file
if [ -f "$HOSTS_FILE" ]; then
    HOST_DOMAINS=$(grep "^127\.0\.0\.1" "$HOSTS_FILE" 2>/dev/null | sed 's/127\.0\.0\.1//' | tr '[:space:]' '\n' | grep -v "^broadcasthost$" | grep -v "^$" | sort -u | tr '\n' ' ')
    ALL_DOMAINS="$ALL_DOMAINS $HOST_DOMAINS"
fi

# Deduplicate domains preserving unique tokens
DOMAINS=$(echo "$ALL_DOMAINS" | tr '[:space:]' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

# Check if mkcert is installed
if ! command -v mkcert &> /dev/null; then
    echo "❌ Error: 'mkcert' is not installed. Please install it first (e.g., brew install mkcert)."
    exit 1
fi

echo "   🚀 Generating local certificates with mkcert..."

MKCERT_OUT=$(mkcert -cert-file "$CERT_DIR/local-cert.pem" -key-file "$CERT_DIR/local-key.pem" $DOMAINS 2>&1)
MKCERT_STATUS=$?
if [ -n "$MKCERT_OUT" ]; then
    echo "$MKCERT_OUT" | sed 's/^/      /'
fi

if [ $MKCERT_STATUS -eq 0 ]; then
    chmod 644 "$CERT_DIR/local-cert.pem" 2>/dev/null || true
    chmod 600 "$CERT_DIR/local-key.pem" 2>/dev/null || true
    echo "   ✨ Successfully generated local certificates."
else
    echo "❌ Error: mkcert failed to generate certificates."
    exit 1
fi
