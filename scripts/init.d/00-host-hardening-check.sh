#!/bin/bash

# =============================================================================
# PHASE 0: Host Hardening Pre-Flight Check
# =============================================================================
# Warns if production-grade host-level hardening is missing.
# This is informational only — it never blocks the stack from starting.
#
# NOTE: This script is designed to be SOURCED by start.sh. Executing it
#       directly may produce a harmless "return: can only `return'..." message.
#
# Checks:
#   1. Anti-DDoS sysctl parameters (Linux hosts only)
#   2. CrowdSec Firewall Bouncer installation (Linux hosts only)
#   3. File descriptor limits (ulimit)
#   4. Swap presence (undesirable for network containers)
#   5. Docker live-restore (containers survive daemon restarts)
#   6. vm.overcommit_memory (recommended for Redis/Valkey stability)
#
# Skipped entirely when running inside a container, because we cannot
# inspect or modify the host kernel from within a namespaced environment.
# =============================================================================

# Skip if running inside a container — we can't inspect the host kernel
if [ -f /.dockerenv ] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
    return 0
fi

# Skip on non-Linux platforms (macOS, WSL without native sysctl, etc.)
if [ "$(uname -s)" != "Linux" ]; then
    return 0
fi

echo ""
echo "── [0/6] 🔍 Checking host-level hardening ───────────────────────────────"

WARNINGS=0

# ---------------------------------------------------------------------------
# 1. Anti-DDoS Sysctl Checks
# ---------------------------------------------------------------------------
# We only warn if the value is present but below the recommended threshold.
# If sysctl fails (e.g. parameter doesn't exist), we silently skip that check.

check_sysctl() {
    local param="$1"
    local min_val="$2"
    local current_val

    current_val=$(sysctl -n "$param" 2>/dev/null)
    if [ -n "$current_val" ] && [ "$current_val" -lt "$min_val" ] 2>/dev/null; then
        echo "   ⚠️  $param = $current_val (recommended: ≥ $min_val)"
        return 1
    fi
    return 0
}

SYSCTL_ISSUES=0

check_sysctl "net.core.rmem_max"              7500000  || SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
check_sysctl "net.core.wmem_max"              7500000  || SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
check_sysctl "net.core.netdev_max_backlog"    10000    || SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
check_sysctl "net.ipv4.tcp_max_syn_backlog"   8192     || SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))

# net.netfilter.nf_conntrack_max may not exist on all kernels (e.g. minimal LXC)
if sysctl -n "net.netfilter.nf_conntrack_max" >/dev/null 2>&1; then
    check_sysctl "net.netfilter.nf_conntrack_max" 262144 || SYSCTL_ISSUES=$((SYSCTL_ISSUES + 1))
fi

if [ $SYSCTL_ISSUES -gt 0 ]; then
    echo ""
    echo "   💡 Host kernel tuning is incomplete. Run this block:"
    echo ""
    echo "sudo tee /etc/sysctl.d/99-traefik-anti-ddos.conf > /dev/null <<'EOF'"
    echo "# HTTP/3 (QUIC / UDP) socket buffers — prevents packet drops at 10,000+ req/s"
    echo "net.core.rmem_max = 7500000"
    echo "net.core.wmem_max = 7500000"
    echo ""
    echo "# Backlog queues"
    echo "net.core.netdev_max_backlog = 10000"
    echo "net.ipv4.tcp_max_syn_backlog = 8192"
    echo ""
    echo "# TCP optimization"
    echo "net.ipv4.tcp_tw_reuse = 1"
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_keepalive_time = 60"
    echo ""
    echo "# Conntrack table (critical for Docker + nftables)"
    echo "net.netfilter.nf_conntrack_max = 262144"
    echo ""
    echo "# Valkey/Redis"
    echo "vm.overcommit_memory = 1"
    echo "EOF"
    echo "sudo sysctl --system"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ Anti-DDoS sysctl parameters look good."
fi

# ---------------------------------------------------------------------------
# 2. CrowdSec Firewall Bouncer Check
# ---------------------------------------------------------------------------
# The container-based Traefik plugin blocks at Layer 7. The firewall bouncer
# drops packets at netfilter (nftables/iptables) before they reach Docker.
# This is the most effective DDoS mitigation layer.

CSFWB_INSTALLED=false
CSFWB_ACTIVE=false

# Check multiple possible binary names and common paths
for cmd in cs-firewall-bouncer crowdsec-firewall-bouncer; do
    if command -v "$cmd" >/dev/null 2>&1; then
        CSFWB_INSTALLED=true
        break
    fi
    # Also check common absolute paths in case PATH is incomplete
    for prefix in /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do
        if [ -x "$prefix/$cmd" ]; then
            CSFWB_INSTALLED=true
            break 2
        fi
    done
done

# Fallback: verify the package is installed via dpkg
if [ "$CSFWB_INSTALLED" = false ] && command -v dpkg >/dev/null 2>&1; then
    if dpkg -l | grep -qE "crowdsec-firewall-bouncer|cs-firewall-bouncer"; then
        CSFWB_INSTALLED=true
    fi
fi

# Check service status using multiple possible service names
CSFWB_SERVICE=""
CSFWB_ENABLED=false
for svc in cs-firewall-bouncer crowdsec-firewall-bouncer; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        CSFWB_ACTIVE=true
        CSFWB_SERVICE="$svc"
        break
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
        CSFWB_SERVICE="$svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        CSFWB_ENABLED=true
    fi
done

if [ "$CSFWB_INSTALLED" = false ]; then
    echo "   ⚠️  CrowdSec Firewall Bouncer is NOT installed on the host."
    echo "      Without it, malicious traffic still reaches Traefik before being blocked."
    echo "      Add the CrowdSec APT repository, then install:"
    echo "        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash"
    echo "        # If the script fails on Debian 13 (Trixie), force the Bookworm codename:"
    echo "        #   sudo sed -i 's/trixie/bookworm/g' /etc/apt/sources.list.d/crowdsec_crowdsec.list"
    echo "        sudo apt update && sudo apt install crowdsec-firewall-bouncer-nftables"
    WARNINGS=$((WARNINGS + 1))
elif [ "$CSFWB_INSTALLED" = true ] && [ "$CSFWB_ACTIVE" = false ]; then
    echo "   ⚠️  CrowdSec Firewall Bouncer is installed but NOT running."

    # Check who owns port 8090 on the host
    PORT_OWNER=""
    if command -v ss >/dev/null 2>&1; then
        PORT_OWNER=$(ss -tlnp 2>/dev/null | awk '/:8090 / {for(i=1;i<=NF;i++) if($i ~ /users:/) print $i}' | sed 's/.*"\([^"]*\)".*/\1/')
    elif command -v lsof >/dev/null 2>&1; then
        PORT_OWNER=$(lsof -i :8090 -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')
    fi

    if [ -n "$PORT_OWNER" ] && [ "$PORT_OWNER" != "docker-proxy" ]; then
        echo "      Port 8090 is occupied by '$PORT_OWNER' — CrowdSec LAPI cannot bind."
        echo "      Free the port or change the mapping in docker-compose-security.yaml."
        WARNINGS=$((WARNINGS + 1))
    else
        # Port is either free or owned by docker-proxy (expected). The issue is config.
        echo "      The bouncer is installed but the systemd service is not active."
        if [ "$CSFWB_ENABLED" = false ]; then
            echo "      It is also not enabled to start on boot."
        fi
        echo ""
        if [ "$PORT_OWNER" = "docker-proxy" ]; then
            echo "      ✅ CrowdSec LAPI is already exposed on port 8090."
            echo "         Most likely causes: the service was never enabled, or it lacks a valid API key."
            echo ""
        else
            echo "      1. Restart the stack so CrowdSec exposes the LAPI on port 8090:"
            echo "           make restart"
            echo ""
        fi
        echo "      2. Enable and start the service:"
        if [ -n "$CSFWB_SERVICE" ]; then
            echo "           sudo systemctl enable $CSFWB_SERVICE"
            echo "           sudo systemctl start  $CSFWB_SERVICE"
        else
            echo "           sudo systemctl enable crowdsec-firewall-bouncer"
            echo "           sudo systemctl start  crowdsec-firewall-bouncer"
        fi
        echo ""
        echo "      3. If it still fails, generate a bouncer API key inside the CrowdSec container:"
        echo '           CROWDSEC=$(docker ps --filter "label=com.docker.compose.service=crowdsec" --format "{{.Names}}" | head -n1)'
        echo '           docker exec "$CROWDSEC" cscli bouncers add firewall-bouncer -o raw'
        echo ""
        echo "         Then paste the key into /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
        echo "         under 'api_key', ensure 'api_url: http://127.0.0.1:8090', and restart the service."
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "   ✅ CrowdSec Firewall Bouncer is installed and active."
fi

# ---------------------------------------------------------------------------
# 3. File Descriptor Limits
# ---------------------------------------------------------------------------
# Traefik opens one file descriptor per connection. Under high load or DDoS,
# the default 1024 limit is exhausted almost immediately.

# Detect LXC container — systemd limits do not apply there
IS_LXC=false
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt --container 2>/dev/null || systemd-detect-virt 2>/dev/null)
    if [ "$VIRT_TYPE" = "lxc" ]; then
        IS_LXC=true
    fi
elif [ -d /dev/lxc ] || [ -n "${container:-}" ]; then
    IS_LXC=true
elif grep -q 'lxc' /proc/1/cgroup 2>/dev/null; then
    IS_LXC=true
elif cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep -q '^container=lxc'; then
    IS_LXC=true
fi

FD_LIMIT=$(ulimit -n 2>/dev/null || echo "1024")
    if [ -n "$FD_LIMIT" ] && [ "$FD_LIMIT" -lt 65535 ] 2>/dev/null; then
    echo "   ⚠️  Open file descriptor limit is $FD_LIMIT (recommended: ≥ 65535)."
    if [ "$IS_LXC" = true ]; then
        echo "      This is an LXC container. systemd limits do not apply here."
        echo "      The fix depends on whether the Proxmox host already allows a high limit."
        echo ""
        echo "      Step 1 — configure PAM inside the container:"
        echo '        echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/sshd'
        echo '        echo "* soft nofile 65535" | sudo tee /etc/security/limits.d/99-nofile.conf'
        echo '        echo "* hard nofile 65535" | sudo tee -a /etc/security/limits.d/99-nofile.conf'
        echo ""
        echo "      Step 2 — close ALL SSH sessions (including multiplexed connections)"
        echo "      and reconnect. Verify with: ulimit -n"
        echo ""
        echo "      If it still shows 1024, the Proxmox host is capping the container."
        echo "      From the Proxmox node, edit /etc/pve/lxc/<id>.conf and add:"
        echo "        lxc.prlimit.nofile: 65535"
        echo "      Then restart the container from Proxmox: pct reboot <id>"
    else
        echo "      To apply the fix immediately:"
        echo ""
        echo "      1. echo 'DefaultLimitNOFILE=65535' | sudo tee -a /etc/systemd/system.conf /etc/systemd/user.conf"
        echo "      2. sudo systemctl daemon-reexec"
        echo "      3. exit    # close your current SSH session"
        echo "      4. Reconnect via SSH and verify with: ulimit -n"
        echo ""
        echo "      If you still see 1024 after reconnecting, a PAM limit may be overriding it."
        echo "      In that case, also run:"
        echo "        echo '* soft nofile 65535' | sudo tee /etc/security/limits.d/99-nofile.conf"
        echo "        echo '* hard nofile 65535' | sudo tee -a /etc/security/limits.d/99-nofile.conf"
        echo "      Then exit and reconnect again."
    fi
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ File descriptor limit looks good ($FD_LIMIT)."
fi

# ---------------------------------------------------------------------------
# 4. Swap Presence
# ---------------------------------------------------------------------------
# Swap introduces unpredictable latency spikes. Network proxies (Traefik)
# and in-memory databases (Valkey) must never be paged out.

SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    echo "   ⚠️  Swap is enabled on this host (${SWAP_TOTAL} kB)."
    echo "      Disable it now and persist the change:"
    echo "        sudo swapoff -a"
    echo "        sudo sed -i '/^[^#].*swap/s/^/# /' /etc/fstab"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ Swap is disabled (optimal for network containers)."
fi

# ---------------------------------------------------------------------------
# 5. Docker Live-Restore
# ---------------------------------------------------------------------------
# Without live-restore, restarting the Docker daemon (e.g. during an upgrade)
# kills ALL running containers, including Traefik and CrowdSec.

if [ -f /etc/docker/daemon.json ]; then
    if command -v jq >/dev/null 2>&1; then
        LIVE_RESTORE=$(jq -r '."live-restore" // false' /etc/docker/daemon.json 2>/dev/null)
        if [ "$LIVE_RESTORE" != "true" ]; then
            echo "   ⚠️  Docker live-restore is NOT enabled."
            echo "      Run these commands to enable it (containers will survive daemon restarts):"
            echo ""
            echo '      sudo tee /etc/docker/daemon.json > /dev/null <<EOF'
            echo '      {"live-restore": true}'
            echo '      EOF'
            echo "      sudo systemctl restart docker"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "   ✅ Docker live-restore is enabled."
        fi
    else
        # jq not installed — do a simple grep
        if ! grep -q '"live-restore".*true' /etc/docker/daemon.json 2>/dev/null; then
            echo "   ⚠️  Docker live-restore status could not be verified (jq not installed)."
            echo "      Run these commands to ensure it is enabled:"
            echo ""
            echo '      sudo tee /etc/docker/daemon.json > /dev/null <<EOF'
            echo '      {"live-restore": true}'
            echo '      EOF'
            echo "      sudo systemctl restart docker"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "   ✅ Docker live-restore appears enabled."
        fi
    fi
else
    echo "   ⚠️  /etc/docker/daemon.json not found. Docker live-restore is likely disabled."
    echo "      Run these commands to create it and enable live-restore:"
    echo ""
    echo '      sudo tee /etc/docker/daemon.json > /dev/null <<EOF'
    echo '      {"live-restore": true}'
    echo '      EOF'
    echo "      sudo systemctl restart docker"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 6. vm.overcommit_memory
# ---------------------------------------------------------------------------
# Valkey/Redis recommend overcommit_memory=1 to prevent the OOM killer
# from triggering during fork() operations (even with persistence disabled).

if command -v sysctl >/dev/null 2>&1 || [ -x /usr/sbin/sysctl ] || [ -x /sbin/sysctl ] || [ -x /bin/sysctl ]; then
    OVERCOMMIT=$(/usr/sbin/sysctl -n vm.overcommit_memory 2>/dev/null || /sbin/sysctl -n vm.overcommit_memory 2>/dev/null || /bin/sysctl -n vm.overcommit_memory 2>/dev/null || sysctl -n vm.overcommit_memory 2>/dev/null)
    if [ -n "$OVERCOMMIT" ] && [ "$OVERCOMMIT" -ne 1 ] 2>/dev/null; then
        echo "   ⚠️  vm.overcommit_memory = $OVERCOMMIT (recommended: 1)."
        echo "      Run: sudo sysctl -w vm.overcommit_memory=1"
        echo "      (Already included in the sysctl block above if you applied it.)"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ vm.overcommit_memory is correctly set to 1."
    fi
else
    echo "   ⚠️  Cannot check vm.overcommit_memory (sysctl not found in PATH)."
    echo "      It may be installed but not in your PATH. Run: sudo /usr/sbin/sysctl -w vm.overcommit_memory=1"
    echo "      (Already included in the sysctl block above if you applied it.)"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ $WARNINGS -eq 0 ]; then
    echo "   ✅ Host hardening checks passed."
else
    echo ""
    echo "   🛡️  These are recommendations, not blockers. The stack will start normally."
    echo "      For maximum DDoS resilience, address the items above before going to"
    echo "      high-traffic production. Details are in README.md -> Production Hardening."
fi

return 0
