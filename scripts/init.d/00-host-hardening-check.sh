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

if command -v cs-firewall-bouncer >/dev/null 2>&1; then
    CSFWB_INSTALLED=true
fi

if systemctl is-active --quiet cs-firewall-bouncer 2>/dev/null; then
    CSFWB_ACTIVE=true
fi

if [ "$CSFWB_INSTALLED" = false ]; then
    echo "   ⚠️  CrowdSec Firewall Bouncer is NOT installed on the host."
    echo "      Without it, malicious traffic still reaches Traefik before being blocked."
    echo "      Add the CrowdSec APT repository, then install:"
    echo "        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash"
    echo "        sudo apt update && sudo apt install crowdsec-firewall-bouncer-nftables"
    WARNINGS=$((WARNINGS + 1))
elif [ "$CSFWB_INSTALLED" = true ] && [ "$CSFWB_ACTIVE" = false ]; then
    echo "   ⚠️  CrowdSec Firewall Bouncer is installed but NOT running."
    echo "      Start it with: systemctl start cs-firewall-bouncer"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ CrowdSec Firewall Bouncer is installed and active."
fi

# ---------------------------------------------------------------------------
# 3. File Descriptor Limits
# ---------------------------------------------------------------------------
# Traefik opens one file descriptor per connection. Under high load or DDoS,
# the default 1024 limit is exhausted almost immediately.

FD_LIMIT=$(ulimit -n 2>/dev/null || echo "1024")
if [ -n "$FD_LIMIT" ] && [ "$FD_LIMIT" -lt 65536 ] 2>/dev/null; then
    echo "   ⚠️  Open file descriptor limit is $FD_LIMIT (recommended: ≥ 65536)."
    echo "      Run these commands to raise the limit permanently:"
    echo ""
    echo "      echo 'DefaultLimitNOFILE=65536' | sudo tee -a /etc/systemd/system.conf /etc/systemd/user.conf"
    echo "      sudo systemctl daemon-reexec"
    echo "      # Verify with: ulimit -n"
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
    echo "      For consistent latency, disable swap: 'swapoff -a' and"
    echo "      comment out the swap line in /etc/fstab."
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
            echo "      Add '{\"live-restore\": true}' to /etc/docker/daemon.json"
            echo "      and restart the Docker daemon to survive daemon upgrades."
            WARNINGS=$((WARNINGS + 1))
        else
            echo "   ✅ Docker live-restore is enabled."
        fi
    else
        # jq not installed — do a simple grep
        if ! grep -q '"live-restore".*true' /etc/docker/daemon.json 2>/dev/null; then
            echo "   ⚠️  Docker live-restore status could not be verified (jq not installed)."
            echo "      Ensure /etc/docker/daemon.json contains {\"live-restore\": true}."
            WARNINGS=$((WARNINGS + 1))
        else
            echo "   ✅ Docker live-restore appears enabled."
        fi
    fi
else
    echo "   ⚠️  /etc/docker/daemon.json not found. Docker live-restore is likely disabled."
    echo "      Create it with '{\"live-restore\": true}' and restart the Docker daemon."
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 6. vm.overcommit_memory
# ---------------------------------------------------------------------------
# Valkey/Redis recommend overcommit_memory=1 to prevent the OOM killer
# from triggering during fork() operations (even with persistence disabled).

OVERCOMMIT=$(sysctl -n vm.overcommit_memory 2>/dev/null)
if [ -n "$OVERCOMMIT" ] && [ "$OVERCOMMIT" -ne 1 ] 2>/dev/null; then
    echo "   ⚠️  vm.overcommit_memory = $OVERCOMMIT (recommended: 1)."
    echo "      Set it with: sysctl -w vm.overcommit_memory=1"
    echo "      Or persist it in /etc/sysctl.d/99-traefik-anti-ddos.conf"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ vm.overcommit_memory is correctly set to 1."
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
