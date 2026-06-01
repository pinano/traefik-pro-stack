# Configuration Guide: LXC Container `<container-name>` — Debian 13 (Trixie) on Proxmox VE [Ext4 Host]

Step-by-step guide to create an unprivileged LXC container optimized to run the full infrastructure stack (Traefik + CrowdSec + Anubis + Grafana/Loki/Prometheus) serving dozens of dockerized websites.

The admin username is configurable and is set during the bootstrap script (Section 3).

---

## 1. Prerequisites & Considerations

*   **LXC vs VM:** LXC offers near-bare-metal performance with minimal RAM and CPU overhead compared to KVM. Since it shares the kernel with the host, Docker runs without any virtualization penalty.
*   **Storage (Ext4):** Docker will use the native `overlay2` storage driver out of the box. No extra configuration (such as `fuse-overlayfs` on ZFS) is required.
*   **Security:** Unprivileged container. If the container is compromised, the attacker does not gain root access to the Proxmox host.

> [!CAUTION]
> **Docker inside LXC is not officially supported by Proxmox.** Proxmox recommends using a VM for production Docker workloads. That said, LXC with `nesting` enabled is stable and widely used in real production environments. The main risk is that updates to `containerd` or the Proxmox kernel can occasionally break compatibility, requiring manual intervention. If you experience permission errors starting containers after an update, consult the Troubleshooting section at the end of this guide.

---

## 2. Phase 1: LXC Container Creation in Proxmox VE

### A. Sizing

The full stack, with all services at their configured limits, consumes approximately:

| Service | Memory Limit |
|---|---|
| Traefik | 2 GB |
| CrowdSec | 2 GB |
| Loki | 2 GB |
| Grafana | 1 GB |
| Alloy | 1 GB |
| Prometheus | 512 MB |
| CrowdSec Web UI | 512 MB |
| Dashboard | 512 MB |
| Redis (Valkey) | 256 MB |
| Redis Exporter | 128 MB |
| Watchdog | 96 MB |
| Dozzle | 64 MB |
| Anubis (×N instances, 32 MB each) | ~320 MB (×10) |
| Anubis Assets (nginx) | 64 MB |
| Backrest (Restic Web UI) | 1 GB |
| **Total services** | **~11.5 GB** |
| Base OS + Docker daemon + overhead | ~1.5 GB |
| **Total recommended** | **~13 GB** |

> [!NOTE]
> These are the **maximum limits** defined in the compose files, not the typical real consumption. Idle, the stack consumes significantly less (~3-4 GB). With 8 GB of RAM, the stack will function correctly under moderate load; 12 GB or more provides margin for traffic spikes and for scaling the number of Anubis instances.

### B. Creation Parameters in Proxmox

1.  **General:**
    *   **Hostname:** `<container-name>`
    *   **Unprivileged container:** **Yes** (Check)
2.  **Template:**
    *   Official **Debian 13 (Trixie)** template.
3.  **Disks:**
    *   **Storage:** Local storage (ext4).
    *   **Disk size:** Minimum **50 GB**. Loki and Prometheus accumulate telemetry data, and Docker logs (`json-file`) occupy additional space. If you plan to serve dozens of webs with high metrics retention, consider 80-100 GB.
4.  **CPU:**
    *   Minimum **4 Cores**. The CrowdSec WAF (AppSec) and Traefik's dynamic config generation benefit significantly from more cores under load.
5.  **Memory:**
    *   **RAM:** Minimum **8192 MB (8 GB)**. Recommended **12288 MB (12 GB)**.
    *   **Swap:** **2048 MB (2 GB)**.
6.  **Network:**
    *   Configure a **static IP** so that your domain DNS records reliably point to the container.

---

### C. Config Template and Features (`/etc/pve/lxc/XXX.conf`)

For Proxmox VE 9.2 (and 9.x versions in general), the optimal configuration for your LXC containers running Docker (like `<container-name>`) should be as clean and native as possible.

By using the template proposed below, you enable **Nesting** and **Keyctl** directly in the configuration file. These two options are **critical and mandatory** for Docker to create its own namespaces and mount isolated filesystems within the unprivileged LXC.

> [!WARNING]
> **Do not use `lxc.apparmor.profile: unconfined`** unless strictly necessary due to a specific failure. Disabling AppArmor removes the final layer of isolation between the container and the Proxmox host. With `nesting=1` and `keyctl=1` in an unprivileged container, Docker runs correctly under the secure standard profile.

#### Recommended Template for Host Configuration File:

```ini
# --- Identity and Architecture ---
arch: amd64
ostype: debian
hostname: <container-name>
tags: docker,infrastructure

# --- CPU and Memory Resources (Adjust as needed) ---
cores: <number-of-cores>
# cpulimit: <cpu-limit>
# cpuunits: <cpu-units-weight>
memory: <memory-mb>
swap: <swap-mb>

# --- File Descriptor Limits (ulimit) ---
# Sets the open file descriptor limits (soft/hard) for the container processes
lxc.prlimit.nofile: 65535:65535

# --- Timezone Synchronization ---
# Container automatically inherits the Proxmox host timezone
timezone: host

# --- Storage (Adjust <vmid> and <disk-size>) ---
# Local path on ext4 host (uses native overlay2 storage driver for Docker)
# Once started, resize disk from the Proxmox UI 
rootfs: local:<vmid>/vm-<vmid>-disk-0.raw,size=4G

# --- Network and Firewall ---
# firewall=1 enables Proxmox VE firewall for this container
net0: name=eth0,bridge=vmbr0,firewall=1,hwaddr=<MAC_ADDRESS>,ip=<STATIC_IP>/<CIDR_MASK>,gw=<GATEWAY_IP>,type=veth
onboot: 1

# --- Mount Points / Bind Mounts ---
# Optional: Bind mount host directories into the LXC if needed.
# Example: mp0: /srv/shared,mp=/shared

# --- Security and Nesting (CRITICAL!) ---
unprivileged: 1
features: keyctl=1,nesting=1

# --- Environment Variables (Host -> LXC) ---
# Defines variables visible inside the container (see bootstrap propagation below)
lxc.environment: PROXMOX_HOST=pve-node-01
```

#### Key Parameter Details:

1.  **`features: keyctl=1,nesting=1`**:
    *   Natively enables support for Docker to create namespaces and mount its internal filesystems under cgroup v2 in Proxmox VE 9.x.
2.  **`swap: 2048`**:
    *   Provides 2 GB of swap space to support the observability stack (Loki, Prometheus) or CrowdSec spikes.
3.  **`lxc.prlimit.nofile: 65535:65535`**:
    *   Sets the open file limit for all container processes from boot, required for the high number of descriptors needed by Traefik and Alloy.
4.  **`timezone: host`**:
    *   Automatically and natively synchronizes the Proxmox host timezone in the container to ensure correct timestamps in logs.
5.  **`lxc.environment: PROXMOX_HOST=pve-node-01`**:
    *   Injects the variable into the container's init process (PID 1). The subsequent bootstrap script will read and persist this variable in the global system environment (`/etc/environment`) so it is visible in any session or scheduled task.
6.  **`cpulimit` and `cpuunits` (Optional)**:
    *   `cpulimit: <limit>` (e.g., `4`): Limits the maximum real CPU assigned to the container, regardless of cores visible in `cores`.
    *   `cpuunits: <weight>` (e.g., `512`): Assigns relative CPU priority (default is `1024`) during high contention on the Proxmox host.

---

## 3. Phase 2: Automated Container Configuration (Bootstrap)

To minimize manual steps once the `<container-name>` container is created and started, we will use a single bootstrap script. This script will:
*   Configure system **locales** (en_US.UTF-8) and **timezone** (default: Europe/Madrid).
*   *Note on NTP:* In unprivileged LXC containers, NTP synchronization cannot run inside the container because it lacks the `SYS_TIME` capability. The container automatically inherits the time of the Proxmox host. Thus, we do not install or run any NTP daemon here.
*   Automate system updates and install essential utilities (`htop`, `btop`, `zabbix-agent2`, and `ctop` for Docker container monitoring).
*   Download and configure the `git-prompt.sh` script to customize the user's terminal prompt.
*   Create the admin user, configure `.bashrc` environments, set up SSH keys, harden SSH, and install Docker configured to use the `overlay2` driver.

### A. Running the Bootstrap Script

Start the container, log in through the Proxmox console as `root`, and execute the following command block:

```bash
# 1. Create the bootstrap script in the container
cat <<'EOF' > /tmp/bootstrap.sh
#!/bin/bash
set -euo pipefail

USER_NAME="<your-admin-username>"   # ← EDIT: Set to the desired admin username for this LXC
SSH_PUBKEY="your-ssh-public-key-here" # Change this to your public SSH key (optional)
TZ_VAL="Europe/Madrid"              # ← EDIT: Set to your desired timezone
ZABBIX_SERVER="your-zabbix-server-ip"       # ← EDIT: Set your Zabbix Server IP/Hostname
ZABBIX_SERVER_ACTIVE="your-zabbix-server-ip" # ← EDIT: Set your Zabbix Server Active IP/Hostname

echo "=== Starting LXC Bootstrap ==="

# System update and essential package installation
echo "1. Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y sudo curl git tmux make dnsutils openssl python3 python3-venv locales htop btop zabbix-agent2

# Configure Locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Configure Timezone
ln -fs "/usr/share/zoneinfo/$TZ_VAL" /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# Install ctop (Docker metrics UI)
echo "Installing ctop..."
curl -fsSL https://github.com/bcicen/ctop/releases/download/v0.7.7/ctop-0.7.7-linux-amd64 -o /usr/local/bin/ctop
chmod +x /usr/local/bin/ctop

# Install git-prompt.sh
echo "Downloading git-prompt.sh..."
curl -fsSL https://raw.githubusercontent.com/git/git/refs/heads/master/contrib/completion/git-prompt.sh -o /usr/local/bin/git-prompt.sh
chmod +x /usr/local/bin/git-prompt.sh

# Create admin user
echo "2. Creating admin user: $USER_NAME..."
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$USER_NAME"
fi
usermod -aG sudo "$USER_NAME"
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER_NAME
chmod 440 /etc/sudoers.d/$USER_NAME

# Configure SSH keys and Hardening
echo "3. Configuring SSH..."
USER_HOME=$(eval echo ~$USER_NAME)
mkdir -p "$USER_HOME/.ssh"
if [ "$SSH_PUBKEY" != "your-ssh-public-key-here" ] && [ -n "$SSH_PUBKEY" ]; then
    echo "$SSH_PUBKEY" > "$USER_HOME/.ssh/authorized_keys"
    chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
fi

# Configure .bashrc for admin user and root (Git prompt + aliases)
echo "Configuring shell environments (.bashrc)..."
for HOME_DIR in "$USER_HOME" "/root"; do
    if [ -f "$HOME_DIR/.bashrc" ]; then
        if ! grep -q "git-prompt.sh" "$HOME_DIR/.bashrc"; then
            cat <<'BASHRC' >> "$HOME_DIR/.bashrc"

# Command alias
alias ls='ls --color=auto'
alias ll='ls -al'

# Git prompt
source /usr/local/bin/git-prompt.sh

# Nice prompt
PS1='\[\033[36m\]\u\[\033[m\]@\[\033[32m\]\h:\[\033[33;1m\]\w\[\033[31m\]$(__git_ps1 " (%s)")\[\033[m\] \$ '
export PS1
BASHRC
        fi
    fi
done
chown "$USER_NAME:$USER_NAME" "$USER_HOME/.bashrc"

# SSH Hardening (No root login, no password auth)
cat <<SSH_CONF > /etc/ssh/sshd_config.d/security.conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers $USER_NAME
PermitEmptyPasswords no
SSH_CONF
systemctl restart sshd

# Install Docker
echo "4. Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$USER_NAME"
usermod -aG docker zabbix

# Configure Docker Daemon
echo "5. Configuring Docker Daemon..."
mkdir -p /etc/docker
cat <<'DOCKER_CONF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  },
  "live-restore": true
}
DOCKER_CONF
systemctl restart docker

# Propagate PROXMOX_HOST environment variable if it exists
echo "6. Propagating PROXMOX_HOST variable to the system..."
if tr '\0' '\n' < /proc/1/environ | grep -q PROXMOX_HOST; then
    PROXMOX_HOST_VAL=$(tr '\0' '\n' < /proc/1/environ | grep PROXMOX_HOST | cut -d= -f2-)
    echo "PROXMOX_HOST=$PROXMOX_HOST_VAL" >> /etc/environment
    echo "Persisted: PROXMOX_HOST=$PROXMOX_HOST_VAL"
else
    echo "Warning: PROXMOX_HOST variable not found in PID 1 environment."
fi

# Configure Zabbix Agent 2
echo "7. Configuring Zabbix Agent..."
if [ -f /etc/zabbix/zabbix_agent2.conf ]; then
    sed -i "s/^#\?\s*Server=.*/Server=$ZABBIX_SERVER/" /etc/zabbix/zabbix_agent2.conf
    sed -i "s/^#\?\s*ServerActive=.*/ServerActive=$ZABBIX_SERVER_ACTIVE/" /etc/zabbix/zabbix_agent2.conf
    sed -i "s/^#\?\s*Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agent2.conf
    systemctl enable zabbix-agent2
    systemctl restart zabbix-agent2
    echo "Zabbix Agent 2 configured, enabled, and restarted."
else
    echo "Warning: /etc/zabbix/zabbix_agent2.conf not found."
fi

echo "=== Bootstrap successfully completed ==="
EOF

# ⚠️  IMPORTANT: Before running, open the script and set USER_NAME to your desired admin username:
#   nano /tmp/bootstrap.sh

# 2. Make executable and run the script
chmod +x /tmp/bootstrap.sh
/tmp/bootstrap.sh
```

Once the bootstrap script completes, close the Proxmox web console. All remaining work will be done remotely by connecting via SSH using your public key:

```bash
ssh <your-admin-username>@<IP_OR_HOSTNAME_LXC>
```

### B. Quick Verifications
Since the key parameters were injected directly from the Proxmox configuration template (`XXX.conf`), you can verify immediately that the setup is correct:

1.  **Verify overlay2**:
    ```bash
    docker info | grep "Storage Driver"
    # Should display: Storage Driver: overlay2
    ```
2.  **Verify open file descriptor limit (ulimit)**:
    ```bash
    ulimit -n
    # Should display: 65535 (directly inherited from lxc.prlimit.nofile)
    ```
3.  **Verify Docker socket**:
    ```bash
    docker ps
    # Should list containers without permission errors
    ```

---

## 4. Phase 3: Performance Tuning (Host)

### A. Kernel Adjustments on the Proxmox Host

LXC containers share the host's kernel. The following adjustments are applied **on the Proxmox Host shell** and affect all LXCs globally:

```bash
sudo tee /etc/sysctl.d/99-lxc-docker-performance.conf > /dev/null <<'EOF'
# --- File Descriptors ---
# Required for the number of simultaneous open files by Docker, Traefik, Loki, and Alloy
fs.file-max = 2097152

# --- Inotify Limits ---
# Alloy and Loki monitor hundreds of log files.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# --- Network backlogs and ports ---
# Max TCP backlog queue for pending connections (matches Traefik net.core.somaxconn)
net.core.somaxconn = 4096

# Expand the range of ephemeral ports to prevent exhaustion under high traffic
net.ipv4.ip_local_port_range = 1024 65535

# --- Memory ---
# Silences Redis vm.overcommit_memory warnings (harmless since save is disabled in the stack)
vm.overcommit_memory = 1
EOF

sudo sysctl --system
```

---

## 5. Phase 4: Firewall (Proxmox VE)

> [!WARNING]
> **Do not install or use UFW inside this container.** Docker directly manipulates the `PREROUTING` chain of `iptables`, allowing it to completely bypass UFW incoming rules for any port published with `-p`. This creates a **false sense of security** where a port seems blocked in UFW but is actually accessible from the internet.

The correct protection must be applied at the **Proxmox VE Firewall** level, which filters packets before they reach the container's network stack.

### Configuration in Proxmox VE:
1. Select `<container-name>` in the Proxmox interface.
2. Go to **Firewall** → **Options** → Enable the firewall (`Firewall: Yes`).
3. Configure the default incoming policy to `DROP` (`Input Policy: DROP`).
4. Add the following incoming rules (**In**):

| Direction | Action | Protocol | Port | Comment |
|---|---|---|---|---|
| In | `ACCEPT` | `tcp` | `22` | Administrative SSH |
| In | `ACCEPT` | `tcp` | `80` | HTTP (Let's Encrypt + HTTPS redirect) |
| In | `ACCEPT` | `tcp` | `443` | HTTPS (web traffic protected by Traefik) |
| In | `ACCEPT` | `udp` | `443` | HTTP/3 (QUIC) — required by Traefik |
| In | `ACCEPT` | `tcp` | `22000:22999` | Dynamic SFTP range (Projects 000-999) |
| In | `ACCEPT` | `tcp` | `33000:33999` | Dynamic MySQL range (Projects 000-999) |

> [!TIP]
> If you need to restrict SSH access to a specific IP or range, add the restriction in the **Source** column of the SSH rule (e.g., `192.168.1.0/24`).

---

### A. Efficient and Secure Management of Dynamic Ports (SFTP / MySQL)

To avoid manually opening ports every time you create a new project, the best solution is to use **port range rules** in the Proxmox VE firewall.

Since your projects follow a strict three-digit numerical pattern (000-999), all your ports will fit into fixed ranges of 1000 ports:
*   **SFTP**: `22000:22999` (Port `22` + project ID)
*   **MySQL**: `33000:33999` (Port `33` + project ID)

Proxmox allows you to specify port ranges in the `Dest. port` column using the `start:end` format (e.g., `22000:22999`). By applying these two rules, traffic to any new project you create within those ranges will be automatically forwarded without manual intervention.

> [!CAUTION]
> **Critical Security Risk: Direct Database Exposure**
> Opening the range `33000:33999` directly exposes your MySQL databases to the internet, making them targets for automated scans and brute-force attacks. Consider the following alternatives to mitigate this risk:
>
> 1.  **SSH Tunneling over SFTP (Recommended)**: Clients can connect securely to the database by performing port forwarding through the existing SFTP connection (which runs over SSH). For example:
>     `ssh -L 3306:mysql-container:3306 sftp-user@yourserver.com -p 22123 -N`
>     This allows encrypted access to `127.0.0.1:3306` locally without exposing port 33123 to the outside world.
> 2.  **CrowdSec Integration**: If exposing MySQL directly is an unavoidable business requirement, ensure you add the MySQL parser and collection (`crowdsecurity/mysql`) inside the LXC container, and configure Loki/Alloy to read the logs from the database containers. This way, any IP attempting brute-force attacks on the exposed port will be banned automatically at the edge (Traefik/Cloudflare/Firewall).
> 3.  **IP Filtering (If possible)**: If clients accessing MySQL have static IPs or belong to a corporate range, edit the Proxmox firewall rule to only accept connections from those IPs (`Source`), keeping the global DROP for the rest of the world.

---

## 6. Phase 5: Deployment of the Stack

Log in as your admin user and clone the repository in your preferred directory:

```bash
# 1. Clone the repository
git clone <REPOSITORY_URL> traefik-pro-stack
cd traefik-pro-stack

# 2. Initialize (creates .venv, installs Python dependencies, runs interactive .env generator)
make init

# 3. Validate configuration
make validate

# 4. Start infrastructure (6-phase startup sequence with health checks)
make start
```

---

## 7. Post-Deployment Verification Checklist

After the first `make start`, run the following checks:

```bash
# 1. Check that all containers are running
make status

# 2. Global health check (permissions, Traefik, CrowdSec, Redis, Grafana)
make health

# 3. Verify Docker is using overlay2 (expected on ext4)
docker info | grep "Storage Driver"
# Should display: Storage Driver: overlay2

# 4. Confirm correct open file descriptor limits
ulimit -n
# Should display: 65535

# 5. Verify certificate status
make certs-info

# 6. Check disk usage (baseline reference)
df -h /
docker system df
```

---

## 8. Periodic Maintenance

### Cleaning Up Docker Images

Docker accumulates obsolete images after each `make pull` and rebuild. With dozens of websites, this can consume gigabytes of space. Schedule a periodic cleanup:

```bash
# Manual cleanup on demand
docker system prune -f --filter "until=168h"
```

To automate this, create a systemd timer or a weekly cron job:

```bash
sudo tee /etc/cron.weekly/docker-prune > /dev/null <<'EOF'
#!/bin/bash
# Removes unused images, stopped containers, and build caches older than 7 days
docker system prune -af --filter "until=168h" > /dev/null 2>&1
EOF
sudo chmod +x /etc/cron.weekly/docker-prune
```

### System Updates

```bash
# Security updates for the OS (cron or manual)
sudo apt update && sudo apt upgrade -y

# Update stack Docker images
cd /path/to/docker-pro-stack     # Adjust to the actual stack path in this LXC
make pull
make restart
```

> [!IMPORTANT]
> **Before upgrading Docker (`docker-ce`, `containerd.io`)** in production, check the release notes to confirm no breaking changes affect LXC compatibility. If you use `live-restore: true` in `daemon.json`, containers will continue running while the daemon restarts.

---

## 9. Autonomous Backup Strategy in the LXC Container (Restic + Rclone + Backrest)

The strategy splits responsibility between two independent layers running at different times:

> [!TIP]
> If you do not need backups in this LXC, set `BACKREST_ENABLE=false` in the `.env` file and the service will not be deployed.

1.  **LXC Cron (SQL Dumps Generation):** A script run directly in the LXC OS via a cron task generates consistent dumps of all running Docker databases and places them in the directory configured in `BACKREST_DUMPS_DIR`. This script has native access to the LXC's Docker socket. Each container is processed independently: a failure in one does not interrupt the dump of the others.
2.  **Backrest (Read and upload to cloud):** 15 minutes later, the Backrest scheduler triggers. It reads the already generated dumps from `/userdata/db_dumps` (mounted as **read-only**) and the projects from `/userdata/projects` (also **read-only**). Restic deduplicates and encrypts locally; Rclone uploads the result to the cloud. The Backrest container **does not need access to the Docker socket**.

```
 02:45  LXC Cron → backup-db-dumps.sh
            ├── docker exec mariadb → SQL dump
            └── writes to /var/backups/incoming/
                           │
                    (LXC disk storage)
                           │ (mounted :ro in Backrest)
                           ▼
  03:00  Backrest → reads /userdata/db_dumps + /userdata/projects
            ├── Restic: deduplicates + encrypts
            └── Rclone: uploads to Dropbox / Google Drive / ...
```

---

### A. Recommended Project Structure

Projects should be located under the path defined in `BACKREST_PROJECTS_DIR` in the stack's `.env` file. This path is mounted to `/userdata/projects` inside the Backrest container and can vary across LXCs.

```text
<BACKREST_PROJECTS_DIR>/
├── traefik-pro-stack/           # This repository (Traefik, CrowdSec, etc.)
├── project-001-wordpress/
│   ├── docker-compose.yml
│   ├── html/                    # Source code (included in backup)
│   ├── mariadb_data/            # Active database — excluded in Backrest
│   └── .env                     # Credentials — included in encrypted backup
└── project-002-laravel/
    ├── docker-compose.yml
    ├── src/
    ├── mariadb_data/            # Active database — excluded in Backrest
    └── .env
```

*   `mariadb_data/` is excluded because copying an active database in hot state causes corrupt files. It is backed up via consistent SQL dumps instead.
*   `.env` files **are included** — they contain critical configuration, and the Restic repository is encrypted, so it is safe.

---

### B. SQL Dumps Generation Script

The script is located in the repository at [`scripts/backup-db-dumps.sh`](scripts/backup-db-dumps.sh). Install it in the LXC by copying it directly from the stack directory:

```bash
sudo cp /path/to/traefik-pro-stack/scripts/backup-db-dumps.sh /usr/local/bin/backup-db-dumps.sh
sudo chmod +x /usr/local/bin/backup-db-dumps.sh
```

> [!TIP]
> Adjust the source path to the actual repository location in this LXC. This way, any future updates to the script can be deployed by simply running the `cp` command again.

---

### C. LXC Cron (Execution Prior to Backrest)

The dump must complete before Backrest starts. If Backrest is scheduled at 03:00, execute the dump at 02:45:

```bash
sudo crontab -e
```
Add the following line:
```cron
# Generate fresh DB dumps 15 minutes before the Backrest backup plan runs
45 2 * * * /usr/local/bin/backup-db-dumps.sh >> /var/log/backup-db-dumps.log 2>&1
```

Configure log rotation to avoid accumulating logs indefinitely:
```bash
sudo tee /etc/logrotate.d/backup-db-dumps > /dev/null <<'EOF'
/var/log/backup-db-dumps.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
```

---

### D. Backrest Configuration (Web UI)

All repository, plan, and retention management is performed from `https://dashboard.<your-domain>/backups/`.

#### 1. Configure Rclone inside the Backrest container

We configure `rclone` directly inside the running Backrest container. This keeps the configuration self-contained within the stack's directories (`./config/backrest/rclone/rclone.conf`) and avoids coupling the container to the host system's root files.

> [!IMPORTANT]
> Providers like Dropbox and Google Drive require an OAuth flow that opens a URL in a browser. Since the server is headless, you must run the authorization command on your local PC:
> ```bash
> # On your local PC (with rclone installed):
> rclone authorize "dropbox"    # or "drive" for Google Drive
> # Copy the complete JSON token displayed on screen
> ```
>
> Now, start the interactive config session directly inside the Backrest container and paste the token when prompted:
> ```bash
> # Run the configuration assistant inside the container:
> docker compose exec -it backrest rclone config
> ```

> [!TIP]
> Use a generic name for the remote, such as `cloud-backup`, instead of `dropbox` or `gdrive`. If you change providers in the future, you only need to reconfigure that remote inside the container without modifying any URLs or paths in the Backrest Web UI.

The assistant will automatically write to `/root/.config/rclone/rclone.conf` inside the container, which is persisted on the host at `./config/backrest/rclone/rclone.conf`.

#### 2. Adding the Repository in Backrest

In the Web UI → **Repositories** → **Add Repository**:

- **Repository Path**: `rclone:cloud-backup:backups/restic-repo-<lxc-name>`
  *(Use a unique name per LXC to avoid mixing snapshots from different servers.)*
- **Password**: A strong password. **Save it in an external, secure place** — without it, backups are unrecoverable even if you have access to the repository.

#### 3. Creating the Backup Plan

**Backup Plans** → **Create Plan**:

| Field | Value |
|---|---|
| **Sources** | `/userdata/projects`, `/userdata/db_dumps` |
| **Exclusions** | `**/mariadb_data`, `**/.venv`, `**/node_modules`, `**/.git`, `**/cache` |
| **Pre-backup Hook** | *(Empty — the external cron already generated the dumps)* |
| **Schedule** | `0 3 * * *` (03:00 AM, 15 min after the dump cron) |
| **Keep Daily** | 30 |
| **Keep Weekly** | 26 |
| **Keep Monthly** | 6 |
| **Prune on Forget** | Enabled |

---

## 10. Troubleshooting

### Error: `permission denied` starting containers after upgrading Docker

If after an `apt upgrade` that updates `containerd.io`, containers fail to start with permission errors on `sysctl` or `ip_unprivileged_port_start`:

1. **Verify Proxmox is up to date** — sometimes Proxmox releases patches in `lxc-pve` that resolve these conflicts.
2. **As a last resort**, temporarily add to `/etc/pve/lxc/<ID>.conf`:
   ```ini
   lxc.apparmor.profile: unconfined
   ```
   Restart the container and confirm Docker works. Once Proxmox releases a patch, remove this line to restore AppArmor isolation.

### Host Metrics in Grafana (Node Exporter)

The Alloy container mounts `/proc`, `/sys`, and `/` from the LXC container to generate metrics equivalent to Node Exporter. Note that these metrics reflect the **LXC container resources** (limited by Proxmox), not those of the Proxmox host directly. This is the expected and perfectly valid behavior for monitoring the health of the environment where the stack runs.

If you need to monitor the Proxmox host at the hypervisor level, consider installing `prometheus-pve-exporter` on a separate machine or using Proxmox's native dashboard metrics.
