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
#   6. Docker socket post-restore handler (refreshes stale docker.sock mounts)
#   7. vm.overcommit_memory (recommended for Redis/Valkey stability)
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

# Skip on development/desktop distros (Arch Linux, etc.)
# Host hardening is intended strictly for Debian/Ubuntu production hosts.
if [ -f /etc/arch-release ] || ( [ -f /etc/os-release ] && grep -qiE '^ID(=|_LIKE=).*(arch)' /etc/os-release ); then
    return 0
fi

echo ""
echo "── [0/6] 🔍 Checking host-level hardening ───────────────────────────────"

WARNINGS=0

# Detect LXC container environment (Proxmox LXC vs VM / Bare-metal)
IS_LXC=false
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt --container 2>/dev/null || systemd-detect-virt 2>/dev/null || true)
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

# ---------------------------------------------------------------------------
# 1. Anti-DDoS Sysctl Checks
# ---------------------------------------------------------------------------
# We only warn if the value is present but below the recommended threshold.
# If sysctl fails (e.g. parameter doesn't exist), we silently skip that check.

check_sysctl() {
    local param="$1"
    local min_val="$2"
    local current_val

    current_val=$(sysctl -n "$param" 2>/dev/null || true)
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
    if [ "$IS_LXC" = true ]; then
        echo ""
        echo "   ℹ️  Note: Inside an unprivileged Proxmox LXC container, network sysctls may fail."
        echo "      If 'sysctl --system' shows 'Permission denied', apply the block on the Proxmox host node."
    fi
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
    OS_CODENAME=""
    if [ -f /etc/os-release ]; then
        OS_CODENAME=$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    if [ "$OS_CODENAME" = "trixie" ]; then
        echo "        # Debian 13 (Trixie) requires forcing the Bookworm repository codename:"
        echo "        sudo sed -i 's/trixie/bookworm/g' /etc/apt/sources.list.d/crowdsec_crowdsec.list"
    fi
    echo "        sudo apt update && sudo apt install -y crowdsec-firewall-bouncer-nftables"
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

        BOUNCER_CONF="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
        NEED_URL_FIX=false
        NEED_KEY_FIX=false
        if [ -f "$BOUNCER_CONF" ]; then
            CONF_URL=$(grep -E '^\s*api_url:' "$BOUNCER_CONF" 2>/dev/null | awk '{print $2}' || true)
            CONF_KEY=$(grep -E '^\s*api_key:' "$BOUNCER_CONF" 2>/dev/null | awk '{print $2}' || true)
            if [[ "$CONF_URL" =~ :8080/?$ ]]; then
                NEED_URL_FIX=true
                echo "      ⚠️  $BOUNCER_CONF points to port 8080 ($CONF_URL)."
                echo "         In this stack, CrowdSec LAPI is mapped to 127.0.0.1:8090."
                echo "         Fix: sudo sed -i 's|:8080|:8090|g' $BOUNCER_CONF"
                echo ""
            fi
            if [ -z "$CONF_KEY" ] || [ "$CONF_KEY" = "<API_KEY>" ] || [ "$CONF_KEY" = "\${API_KEY}" ]; then
                NEED_KEY_FIX=true
                echo "      ⚠️  api_key in $BOUNCER_CONF is missing or default."
            fi
        fi

        CROWDSEC_NAME=$(docker ps --filter "label=com.docker.compose.service=crowdsec" --format "{{.Names}}" 2>/dev/null | head -n1)
        if [ -n "$CROWDSEC_NAME" ] && [ "$NEED_KEY_FIX" = true ]; then
            echo "         Generate and write key automatically:"
            echo "           API_KEY=\$(docker exec \"$CROWDSEC_NAME\" cscli bouncers add firewall-bouncer -o raw) && \\"
            echo "           sudo sed -i \"s|^api_key:.*|api_key: \${API_KEY}|\" $BOUNCER_CONF && \\"
            echo "           sudo systemctl restart crowdsec-firewall-bouncer"
            echo ""
        else
            if [ "$PORT_OWNER" != "docker-proxy" ]; then
                echo "      1. Restart the stack so CrowdSec exposes the LAPI on port 8090: make restart"
            fi
            echo "      2. Start and enable the service:"
            echo "           sudo systemctl enable --now ${CSFWB_SERVICE:-crowdsec-firewall-bouncer}"
            if [ "$NEED_KEY_FIX" = true ]; then
                echo "      3. If authentication fails, register the key:"
                echo '           CROWDSEC=$(docker ps --filter "label=com.docker.compose.service=crowdsec" --format "{{.Names}}" | head -n1)'
                echo '           docker exec "$CROWDSEC" cscli bouncers add firewall-bouncer -o raw'
                echo "           Paste the key into $BOUNCER_CONF under 'api_key', ensure 'api_url: http://127.0.0.1:8090', and restart the service."
            fi
        fi
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

FD_LIMIT=$(ulimit -n 2>/dev/null || echo "1024")
if [ -n "$FD_LIMIT" ] && [ "$FD_LIMIT" -lt 65535 ] 2>/dev/null; then
    echo "   ⚠️  Open file descriptor limit is $FD_LIMIT (recommended: ≥ 65535)."
    if [ "$IS_LXC" = true ]; then
        HAS_PAM=$(grep -q "pam_limits.so" /etc/pam.d/sshd 2>/dev/null && echo true || echo false)
        HAS_LIMITS_FILE=$([ -f /etc/security/limits.d/99-nofile.conf ] && grep -qE "6553[56]" /etc/security/limits.d/99-nofile.conf 2>/dev/null && echo true || echo false)

        if [ "$HAS_PAM" = true ] && [ "$HAS_LIMITS_FILE" = true ]; then
            echo "      PAM and security limits are already configured inside this LXC container."
            echo "      The Proxmox host is capping the container to $FD_LIMIT."
            echo "      👉 Fix on the Proxmox VE host node:"
            echo "         Edit /etc/pve/lxc/<id>.conf and add:"
            echo "           lxc.prlimit.nofile: 65535"
            echo "         Then restart the container from Proxmox: pct reboot <id>"
        else
            echo "      This is an LXC container. Configure PAM and security limits inside the container:"
            if [ "$HAS_PAM" = false ]; then
                echo '        echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/sshd'
            fi
            if [ "$HAS_LIMITS_FILE" = false ]; then
                echo "        sudo tee /etc/security/limits.d/99-nofile.conf > /dev/null <<'EOF'"
                echo "* soft nofile 65535"
                echo "* hard nofile 65535"
                echo "EOF"
            fi
            echo "      Then close ALL SSH sessions, reconnect, and verify with: ulimit -n"
            echo "      If it still shows 1024 after reconnecting, the Proxmox host requires 'lxc.prlimit.nofile: 65535'."
        fi
    else
        # VM or Bare-Metal host
        HAS_SYS_LIMIT=$(grep -E '^\s*DefaultLimitNOFILE=(6553[56]|[7-9][0-9]{4}|[1-9][0-9]{5})' /etc/systemd/system.conf 2>/dev/null && echo true || echo false)
        if [ "$HAS_SYS_LIMIT" = true ]; then
            echo "      DefaultLimitNOFILE=65535 is already configured in /etc/systemd/system.conf,"
            echo "      but your current shell session limit is $FD_LIMIT."
            echo "      👉 Apply to systemd and reconnect:"
            echo "         1. sudo systemctl daemon-reexec"
            echo "         2. exit    # Close current SSH session and reconnect"
        else
            echo "      To configure the systemd limit:"
            echo "      1. echo 'DefaultLimitNOFILE=65535' | sudo tee -a /etc/systemd/system.conf /etc/systemd/user.conf"
            echo "      2. sudo systemctl daemon-reexec"
            echo "      3. exit    # Close current SSH session and reconnect"
        fi
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
    if [ "$IS_LXC" = true ]; then
        echo "      In a Proxmox LXC container, swap is controlled by the Proxmox host."
        echo "      👉 From the Proxmox VE host, run: pct set <id> -swap 0"
    else
        FSTAB_SWAP=$(grep -E '\sswap\s' /etc/fstab 2>/dev/null | grep -v '^\s*#' || true)
        if [ -n "$FSTAB_SWAP" ]; then
            echo "      👉 Disable it immediately and persist in /etc/fstab:"
            echo "         sudo swapoff -a"
            echo "         sudo sed -i '/\\sswap\\s/s/^/# /' /etc/fstab"
        else
            echo "      👉 Swap is active but not listed in /etc/fstab (likely systemd zram or swap unit)."
            echo "         sudo swapoff -a"
            echo "         (Inspect active swap units with: systemctl list-units --type=swap)"
        fi
    fi
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
    LIVE_RESTORE=false
    if command -v python3 >/dev/null 2>&1; then
        LIVE_RESTORE=$(python3 -c 'import json; d=json.load(open("/etc/docker/daemon.json")); print(str(d.get("live-restore", False)).lower())' 2>/dev/null || echo "false")
    elif command -v jq >/dev/null 2>&1; then
        LIVE_RESTORE=$(jq -r '."live-restore" // false' /etc/docker/daemon.json 2>/dev/null)
    elif grep -q '"live-restore"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json 2>/dev/null; then
        LIVE_RESTORE=true
    fi

    if [ "$LIVE_RESTORE" != "true" ]; then
        echo "   ⚠️  Docker live-restore is NOT enabled in /etc/docker/daemon.json."
        echo "      Containers will be stopped when the Docker daemon restarts or upgrades."
        echo "      Add '\"live-restore\": true' to /etc/docker/daemon.json:"
        echo ""
        if command -v python3 >/dev/null 2>&1; then
            echo "      # Safely merge into existing JSON without overwriting other settings:"
            echo '      sudo python3 -c '\''import json; p="/etc/docker/daemon.json"; d=json.load(open(p)); d["live-restore"]=True; json.dump(d,open(p,"w"),indent=2)'\'''
        elif command -v jq >/dev/null 2>&1; then
            echo "      sudo jq '. + {\"live-restore\": true}' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.tmp > /dev/null && sudo mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json"
        else
            echo "      Edit /etc/docker/daemon.json and add: \"live-restore\": true"
        fi
        echo "      sudo systemctl restart docker"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ Docker live-restore is enabled."
    fi
else
    echo "   ⚠️  /etc/docker/daemon.json not found. Docker live-restore is disabled."
    echo "      Run these commands to create it and enable live-restore:"
    echo ""
    echo "      sudo mkdir -p /etc/docker"
    echo "      sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'"
    echo "      {"
    echo '        "live-restore": true'
    echo "      }"
    echo "      EOF"
    echo "      sudo systemctl restart docker"
    WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------------------
# 6. Docker Socket Post-Restore Handler (Live-Restore Socket Refresh)
# ---------------------------------------------------------------------------
# With live-restore enabled, daemon restarts leave containers mounting docker.sock
# (e.g. watchdog, docker-socket-proxy) with stale file descriptors, triggering
# false-positive alerts in Watchdog. A systemd ExecStartPost drop-in ensures
# these containers are automatically restarted and pick up the new socket.

if command -v systemctl >/dev/null 2>&1; then
    SOCKET_DROPIN_CONFIGURED=false
    if systemctl cat docker.service 2>/dev/null | grep -E "ExecStartPost=.*docker.*(docker\.sock|restart)" >/dev/null 2>&1; then
        SOCKET_DROPIN_CONFIGURED=true
    fi

    if [ "$SOCKET_DROPIN_CONFIGURED" = true ]; then
        echo "   ✅ Docker socket post-restore handler is configured."
    else
        echo "   ⚠️  Docker socket post-restore handler is NOT configured."
        echo "      With live-restore enabled, daemon restarts leave containers mounting docker.sock"
        echo "      with stale file descriptors, triggering false-positive alerts in Watchdog."
        echo "      Run these commands to automatically refresh socket-dependent containers:"
        echo ""
        echo "      sudo mkdir -p /etc/systemd/system/docker.service.d"
        echo "      sudo tee /etc/systemd/system/docker.service.d/restart-socket-proxies.conf > /dev/null <<'EOF'"
        echo "      [Service]"
        echo "      ExecStartPost=-/bin/sh -c 'sleep 2; /usr/bin/docker ps -q --filter \"volume=/var/run/docker.sock\" | xargs -r /usr/bin/docker restart'"
        echo "      EOF"
        echo "      sudo systemctl daemon-reload"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 7. vm.overcommit_memory
# ---------------------------------------------------------------------------
# Valkey/Redis recommend overcommit_memory=1 to prevent the OOM killer
# from triggering during fork() operations (even with persistence disabled).

if command -v sysctl >/dev/null 2>&1 || [ -x /usr/sbin/sysctl ] || [ -x /sbin/sysctl ] || [ -x /bin/sysctl ]; then
    OVERCOMMIT=$(/usr/sbin/sysctl -n vm.overcommit_memory 2>/dev/null || /sbin/sysctl -n vm.overcommit_memory 2>/dev/null || /bin/sysctl -n vm.overcommit_memory 2>/dev/null || sysctl -n vm.overcommit_memory 2>/dev/null || true)
    if [ -n "$OVERCOMMIT" ] && [ "$OVERCOMMIT" -ne 1 ] 2>/dev/null; then
        echo "   ⚠️  vm.overcommit_memory = $OVERCOMMIT (recommended: 1)."
        OVERCOMMIT_IN_FILE=false
        if grep -rqsE '^\s*vm\.overcommit_memory\s*=\s*1' /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null; then
            OVERCOMMIT_IN_FILE=true
        fi
        if [ "$OVERCOMMIT_IN_FILE" = true ]; then
            echo "      'vm.overcommit_memory = 1' is already in your sysctl files, but not active in the kernel."
            echo "      👉 Apply it now: sudo sysctl --system"
        else
            echo "      👉 Persist the setting in sysctl and apply immediately:"
            echo "         echo 'vm.overcommit_memory = 1' | sudo tee -a /etc/sysctl.d/99-traefik-anti-ddos.conf"
            echo "         sudo sysctl --system"
        fi
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
