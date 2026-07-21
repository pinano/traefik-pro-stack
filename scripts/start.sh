#!/bin/bash

# =============================================================================
# start.sh - Stack Deployment Script
# =============================================================================
# Loads configuration, prepares networks, and deploys the stack safely,
# ensuring security components (CrowdSec/Redis) are operational first.
# =============================================================================

set -e  # Exit on any error

# Suppress LibreSSL warnings on macOS (urllib3 v2 compatibility)
export PYTHONWARNINGS="ignore:urllib3 v2 only supports"

# ⏲️ Start Timer
START_TIME=$(date +%s)

# 0. Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running. Please start Docker and try again."
    exit 1
fi

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "🚀 DEPLOYMENT STARTING..."
echo "────────────────────────────────────────────────────────────────────────"

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

# Verify if DASHBOARD_INTERNAL is set but we are not in a container (L7)
if [[ "$DASHBOARD_INTERNAL" == "true" ]]; then
    if [ ! -f /.dockerenv ] && ! grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        echo "   ⚠️ WARNING: DASHBOARD_INTERNAL=true was set in host environment. Ignoring container logic."
        export DASHBOARD_INTERNAL="false"
    fi
fi

trap cleanup EXIT INT TERM


# =============================================================================
# EXECUTE MODULES
# =============================================================================
for script in ./scripts/init.d/*.sh; do
    if [ -x "$script" ] || [ -f "$script" ]; then
        source "$script"
    fi
done

# =============================================================================
# DONE
# =============================================================================


# ⏲️ Calculate Duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "✅ DEPLOYMENT COMPLETE! (Total time: ${DURATION}s)"
echo "────────────────────────────────────────────────────────────────────────"
echo "🌐 SSO ADMIN DASHBOARD:"
echo "   ➜ https://${DASHBOARD_SUBDOMAIN:-dashboard}.${DOMAIN}/"
echo "────────────────────────────────────────────────────────────────────────"
echo ""
