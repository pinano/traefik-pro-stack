# AGENTS.md — Stack Guide for Assistants and Operators

Welcome. This document explains what this project is, how it works, how to set it up, and how to maintain it without breaking anything. Read it before touching any file.

> **In a hurry?** Jump straight to section [7. TL;DR — Quick Reference](#7-tldr--quick-reference).

---

## 1. What Is This Stack? (In 2 Minutes)

### The Mission

This is a **self-managed, production-ready infrastructure stack** that protects web applications (WordPress, Symfony, Zend, Flask, etc.) with automated defense-in-depth. It is not a test environment: it runs real domains, faces real threats, and must behave reliably under pressure.

Its primary goal: **protect multiple Docker applications (and legacy Apache/PHP services on the host) with a fully automated, configuration-drift-free anti-DDoS and anti-bot system.**

### The 3 Layers of Protection

Imagine an HTTP request arriving at your server. Before it ever touches your application, it passes through 3 lines of defense:

```
Internet → [Layer 1: Traefik + CrowdSec] → [Layer 2: Anubis PoW] → [Layer 3: Your App]
```

1. **Layer 1 — Edge**: Traefik routes traffic, terminates TLS, and applies rate limiting. CrowdSec analyzes logs in real time and blocks malicious IPs. AppSec (WAF) inspects payloads for SQLi, XSS, etc.
2. **Layer 2 — Bot Defense**: Anubis presents a lightweight cryptographic challenge (Proof-of-Work) to unauthenticated browsers. Automated bots cannot solve it; humans barely notice it.
3. **Layer 3 — Backend**: Your application (WordPress, Symfony, etc.) receives only clean, legitimate traffic.

### Who Is It For?

- **People managing multiple domains** on a single server.
- **Teams who need security without being networking experts** — everything is configured via environment variables and a CSV.
- **Environments under automated attack** — scans, brute force, spam bots.

---

## 2. How It Works (Without Diving Into Code)

### The Journey of a Request

1. A visitor types `https://yourdomain.com`.
2. **Traefik** receives the request on port 443, negotiates TLS, and looks up in its dynamic configuration which backend corresponds to that domain.
3. Before routing, it evaluates security rules:
   - Is the User-Agent blacklisted? → 403 immediately.
   - Is the IP banned by CrowdSec? → 403 or CAPTCHA.
   - Does the payload look like an attack (WAF)? → 403.
   - Are there too many requests from that IP? → 429 (rate limit).
4. If the domain has **Anubis** enabled, the visitor receives a cryptographic challenge of 1–3 seconds. Upon solving it, they receive a signed cookie.
5. Finally, the request reaches your Docker container (or the host Apache).

### Networks and Isolation

The stack uses 5 Docker networks to isolate services by risk level:

| Network | Who's on it | What it does |
|---------|------------|-------------|
| **`traefik`** | Traefik, Dashboard, Grafana, Prometheus, Loki, CrowdSec, etc. | Public network where routed traffic flows. |
| **`socket-proxy`** | Docker Proxy (read-only) | Isolates the Docker socket. Traefik, CrowdSec, Alloy, and Dozzle talk to Docker only through this filter. |
| **`socket-proxy-dashboard`** | Docker Proxy (Dashboard — read/write subset) | Isolates the Dashboard's Docker socket access. Only the Dashboard can reach this proxy for soft-restart operations. |
| **`anubis-backend`** | Anubis + Redis/Valkey | Isolated. Anubis can talk to Redis, but not to the Internet. |
| **`crowdsec-backend`** | CrowdSec + PostgreSQL | Isolated. The firewall database never touches the public network. |

### Fail-Open: What Happens If Something Breaks?

By design, the stack **never blocks legitimate traffic because of a failure**:
- If CrowdSec (LAPI) goes down → traffic passes.
- If the WAF (AppSec) goes down → traffic passes.
- If Redis/Valkey goes down → traffic passes.

This prioritizes availability over security in abnormal situations. If you need a "fail-closed" mode (block everything on failure), it must be changed explicitly in the Traefik template.

---

## 3. How to Set It Up

### Requirements

- **Linux** (Debian 12/13, Ubuntu LTS, or Proxmox LXC).
- **Docker Engine ≥ 24.0** + Compose v2 plugin.
- **Python 3.8+** with `venv`.
- Ports **80 and 443 free** on the host.
- A domain pointing to the server (for Let's Encrypt).

### In 3 Commands

```bash
# 1. Initialize the environment (creates .venv, installs dependencies, generates .env)
make init

# 2. Edit .env and domains.csv with your values
nano .env
nano domains.csv

# 3. Start the stack
make start
```

### What to Edit and What NOT to Edit

| ✅ Edit This | ❌ Do Not Touch |
|-----------|----------------|
| `.env` | `traefik-generated.yaml` |
| `domains.csv` | `docker-compose-anubis-generated.yaml` |
| `config/traefik/traefik.yaml.template` | `config/traefik/dynamic-config/*.yaml` |
| `config/crowdsec/acquis-base.yaml` | `config/crowdsec/acquis.yaml` |
| `config/crowdsec/profiles-base.yaml` | `config/crowdsec/profiles.yaml` |
| `config/anubis/botPolicy.yaml` | `config/anubis/botPolicy-generated.yaml` |

**Golden rule**: any file that says "generated" or lives in `dynamic-config/` is regenerated on every `make start`. If you edit it by hand, you will lose your changes.

---

## 4. Technical Architecture

### Components

| Layer | Component | Role |
|------|-----------|-----|
| **Edge Router** | Traefik v3.x | TLS termination, middleware chain, dynamic routing |
| **IPS** | CrowdSec | Collaborative IP reputation, behavioral detection |
| **WAF** | CrowdSec AppSec | Layer-7 inspection (OWASP, virtual patches) |
| **IPS DB** | PostgreSQL 16 | High-concurrency database for CrowdSec LAPI |
| **Bot Defense** | Anubis | Proof-of-Work challenge via ForwardAuth |
| **Session Cache** | Redis / Valkey | Anubis PoW sessions + CrowdSec ban cache |
| **Logs** | Loki | Container log storage and indexing |
| **Metrics** | Prometheus | Time series from all services |
| **Collection** | Grafana Alloy | Container discovery, shipping logs to Loki and metrics to Prometheus |
| **Visualization** | Grafana | Dashboards + managed alerts |
| **Admin UI** | Dashboard (Flask) | `domains.csv` management + SSO provider |
| **Security UI** | CrowdSec Web UI | Web interface for LAPI alerts and decisions |
| **Docker Isolation** | Docker Socket Proxy | Docker API gateway with minimal privileges (HAProxy) |
| **Monitor** | Watchdog | SSL, DNS, CrowdSec health checks → Telegram |
| **Backups** | Backrest (Restic + Rclone) | Encrypted, deduplicated backups to cloud storage |

### How Configuration Is Generated

```
domains.csv + running containers
         │
         ▼
  generate-config.py
         │
         ▼
config/traefik/dynamic-config/*.yaml
         │
         ▼ (hot reload)
      Traefik
```

If you need to add a middleware, router, or service that does not come from `domains.csv`, do it via:
- **Docker labels** on the relevant container, or
- **New logic in `generate-config.py`**.

**Note on redirects**: For redirect-only domains with no backend container, use `noop`, `redirect`, `ping` (or leave blank with redirect) in `domains.csv`. `generate-config.py` automatically binds the router to `ping@internal`, avoiding missing container warnings in Traefik and Watchdog.

**Do not create static YAML files in `dynamic-config/` by hand** — they will be overwritten or conflict on the next `make start`.

### Compose File Modularity

The stack separates responsibilities across multiple files:

| File | Contents |
|---------|-----------|
| `docker-compose-edge.yaml` | Traefik |
| `docker-compose-security.yaml` | CrowdSec, PostgreSQL, Redis, Redis Exporter, CrowdSec Web UI, Docker Socket Proxy |
| `docker-compose-observability.yaml` | Grafana, Loki, Alloy, Prometheus |
| `docker-compose-dashboard.yaml` | Dashboard (Flask), Dozzle, Watchdog, **Docker Socket Proxy (Dashboard)** |
| `docker-compose-anubis.yaml` | Base Anubis template + asset server |
| `docker-compose-anubis-generated.yaml` | Auto-generated Anubis instances (per TLD) |
| `docker-compose-backrest.yaml` | Backrest (Restic + Rclone) — conditional on `BACKREST_ENABLE=true` |
| `docker-compose-apache-logs.yaml` | Apache log integration (auto-included if Apache is detected) |

The active list of compose files is determined by `scripts/compose-files.sh` — the **single source of truth** used by `start.sh`, `stop.sh`, and the `Makefile`. Never hardcode lists of compose files by hand anywhere else.

### Startup Sequence (`start.sh`)

The script starts in 6 sequential phases:

1. **Env sync**: Merges the structure of `.env.dist` with the existing `.env`; backs up `.env` to `.env.bak`. Never destructive.
2. **Credential sync**: Automatically generates `DASHBOARD_SECRET_KEY`, `CROWDSEC_DB_PASSWORD`, `CROWDSEC_WEB_UI_PASSWORD`, `REDIS_PASSWORD`, `ANUBIS_REDIS_PRIVATE_KEY`, `PROMETHEUS_REMOTE_WRITE_TOKEN` if missing. Detects admin password changes and regenerates bcrypt hashes.
3. **Asset prep**: Copies Anubis `.dist` assets if no overrides exist. Generates `traefik-generated.yaml` from its template. Runs `generate-config.py` to produce all dynamic configuration.
4. **Network + security prep**: Creates Docker networks (`traefik`, `socket-proxy`, `anubis-backend`, `crowdsec-backend`). Generates the CrowdSec IP whitelist. Probes Apache via TCP.
5. **Security-first boot**: Starts Docker Socket Proxy, CrowdSec, PostgreSQL, and Redis first. Health check loop (60s timeout). Traefik does not start until CrowdSec is healthy. The bouncer key is registered/re-registered on every startup.
6. **Full stack start**: All remaining services are launched. `grafana-setup-telegram` is invoked automatically.

**Key invariant**: the script is idempotent — running it multiple times against an already-running stack does minimal work and avoids container recreation.

### CrowdSec Dynamic Configurations

`config/crowdsec/acquis.yaml` is generated from `acquis-base.yaml`. When `CROWDSEC_APPSEC_ENABLE=true`, the AppSec listener block is automatically appended and AppSec collections are injected into `CROWDSEC_COLLECTIONS`.

Similarly, `config/crowdsec/profiles.yaml` is generated from `profiles-base.yaml`. The CAPTCHA remediation profile is only injected if there are active configurations in the CAPTCHA registry (`config/crowdsec/captcha_keys.csv`).

Do not edit `acquis.yaml` or `profiles.yaml` directly — edit their respective `-base.yaml` files.

### Security Model

#### Middleware Chain Order

```
Request → [Redirect Regex (Index 0)] → (if match: 301/302 immediate return)
       → [UA Blacklist Router] → (if match: 403)
       → [CrowdSec Bouncer] → (if IP banned or bad payload: 403; if captcha: presents challenge)
       → [Slowloris Buffer]
       → [Security Headers]
       → [Rate Limiter]
       → [Concurrency Limiter]
       → [Circuit Breaker]
       → [Retry]
       → [ForwardAuth / Anubis] → (if no valid cookie: PoW challenge)
       → [Compression]
       → Backend
```

The **UA Blacklist** is a separate high-priority router, not part of the middleware chain. Changes to this chain require modifying `generate-config.py`.

#### Network Isolation

Five Docker networks:
- **`traefik`** (external, bridged): All services that need Traefik to route to them.
- **`socket-proxy`** (internal, no egress): Isolated proxy providing read-only access to the Docker Engine API (`tcp://docker-socket-proxy:2375`) for Traefik, CrowdSec, Alloy, and Dozzle.
- **`socket-proxy-dashboard`** (internal, no egress): Dedicated proxy for the Dashboard with limited write permissions (`POST=1`, `DELETE=1`, `EXEC=1`). Only the Dashboard can reach this proxy for soft-restart operations.
- **`anubis-backend`** (internal, no egress): Redis and Anubis only. Anubis can talk to Redis but cannot make outbound connections to the Internet.
- **`crowdsec-backend`** (internal, no egress): CrowdSec and PostgreSQL (`crowdsec-db`) only. Completely isolates the IPS database from web-exposed containers.

#### Docker Socket Proxy (Dashboard)

Unlike the global proxy (read-only), the Dashboard needs limited write operations to perform *soft restarts* (create containers, remove orphans, run `docker exec` for SIGHUP). A **dedicated proxy** (`docker-socket-proxy-dashboard`) was added inside `docker-compose-dashboard.yaml` with the minimum required permissions (`POST=1`, `DELETE=1`, `EXEC=1`), keeping dangerous operations blocked (`BUILD`, `IMAGES`, `VOLUMES`, `SWARM`). The Dashboard no longer mounts the host Docker socket directly.

---

## 5. Safe Change Guidelines

### Golden Rules

1. **Be concise and conversational**. No corporate filler. Speak clearly and get to the point.
2. **Robustness first**. Prioritize security, performance, and robustness over convenience. "Quick and dirty" is wrong here. Edge cases matter. Error handling must be elegant.
3. **No hallucinations**. If you are unsure about a Traefik middleware option, a CrowdSec scenario name, or a Grafana API endpoint — **look it up**.
4. **Executive summaries**. When explaining or proposing changes, start with the **why** and the **what** before diving into the **how**.
5. **Verify before reinventing**.
   - Check the `Makefile` — most daily operations already have a target.
   - Check `scripts/` — most automation is already scripted.
   - Check `generate-config.py` — adding a new Traefik config pattern probably means adding a template there.
6. **Respect modularity**. Do not add services to existing compose files if a dedicated new file makes more sense. Do not add Traefik router/middleware config to compose files for services that already handle it via `generate-config.py`.
7. **Generated files are forbidden**. Do not propose editing these directly — they are overwritten on every startup:
   - `config/traefik/dynamic-config/*`
   - `config/traefik/traefik-generated.yaml`
   - `config/crowdsec/acquis.yaml`
   - `config/crowdsec/profiles.yaml`
   - `docker-compose-anubis-generated.yaml`
   If a change is needed, modify the **template or the generator**.
8. **Security is always on the menu**. If you spot a hardening opportunity while working on something else — mention it. Do not implement it silently, but do flag it.

### Common Mistakes

| Mistake | Correct Approach |
|-------|-----------------|
| Editing `dynamic-config/` directly | Edit `generate-config.py` or use Docker labels |
| Adding global Traefik config to compose labels | Edit `traefik.yaml.template` for static config |
| Hardcoding compose file lists by hand | Use / update `compose-files.sh` |
| Suggesting `CROWDSEC_ENABLE=false` as a permanent fix | Disables the firewall entirely. Only valid for temporary debugging. |
| Forgetting that `apache-host` requires Apache running | The TCP probe at startup determines inclusion |
| Setting `TRAEFIK_HSTS_MAX_AGE` to a high value without testing HTTPS first | Always test with a low value (300) first |
| Creating secrets manually and adding them to .env | Use `openssl rand -hex 32` and update via `make init` or `start.sh` auto-sync |
| Forgetting to add a domain to the Turnstile widget configuration | CAPTCHA will fail to load on that domain, acting as an unresolvable ban for affected users. |
| "Fixing" the `chmod 777` fallback in `start.sh` for `./data` | It is intentional. Without `sudo`, `chown 472:472` fails. 777 ensures non-root containers (Grafana/Loki) can write. Do not change it to 775. |
| Using `sed` to replace secrets or emails with special characters | Use Python's `str.replace` or literal string substitution in `init.d/` to prevent syntax errors with `#`, `/`, `&`, or quotes |
| Bypassing the `restart-internal.sh` mutex | `restart-internal.sh` uses a file lock at `/tmp/stack-restart.lock` to prevent race conditions during concurrent YAML generation |

### Useful Commands

Use these instead of raw `docker compose` calls:

```bash
make start            # Full startup sequence (generates config, waits for health, etc.)
make stop             # Graceful shutdown
make restart          # Full stop + start
make restart traefik  # Restart a single service
make rebuild          # Rebuild dashboard and watchdog images
make logs traefik     # Tail logs for a service
make shell crowdsec   # Open a shell in a container
make validate         # Validate .env for errors
make crowdsec-decisions   # List active bans
make crowdsec-unban 1.2.3.4
make crowdsec-db-stats    # Show CrowdSec PostgreSQL DB size, rows, and connections
make crowdsec-db-shell    # Interactive psql terminal in the CrowdSec DB
make certs-info       # Certificate status summary
make check-updates    # Check for Docker image updates in compose files
make help             # Full list of commands
```

---

## 6. Production: Host Hardening

This section documents operational hardening that must be applied **on the host** (outside Docker) for maximum resilience in production (Debian 13.x / Proxmox LXC).

### Kernel Tuning (Debian / Proxmox)

The `sysctls` defined in `docker-compose-edge.yaml` only affect the Traefik container's network namespace. For real line-rate anti-DDoS protection, apply these **on the Linux host** via `/etc/sysctl.d/99-traefik-anti-ddos.conf`:

```ini
# HTTP/3 (QUIC / UDP) socket buffers — prevents packet drops at 10,000+ req/s
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000

# Backlog queues
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_max_syn_backlog = 8192

# TCP optimization
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60

# Conntrack table (critical for Docker + nftables)
net.netfilter.nf_conntrack_max = 262144

# Valkey/Redis
vm.overcommit_memory = 1
```

Reload with: `sysctl --system`

### Host Resources

**File descriptor limits**
Traefik opens one file descriptor per active connection. The Linux default (1024) is exhausted immediately under traffic spikes or DDoS.

```bash
# Check current limit
ulimit -n

# Recommended: configure via systemd (requires daemon-reexec)
echo 'DefaultLimitNOFILE=65536' | sudo tee -a /etc/systemd/system.conf /etc/systemd/user.conf
sudo systemctl daemon-reexec
```

**Swap**
Swap introduces unpredictable latency spikes. Network proxies (Traefik) and in-memory databases (Valkey) should never be paged.

```bash
# Disable swap
sudo swapoff -a
# Comment out swap entries in /etc/fstab to persist across reboots
```

**Docker Live-Restore**
Without live-restore, restarting the Docker daemon (e.g., during an upgrade) kills ALL running containers, including Traefik and CrowdSec.

```bash
# /etc/docker/daemon.json
{
  "live-restore": true
}
# Then: sudo systemctl restart docker
```

### Automated Hardening Verification

`make start` runs a pre-flight check (`scripts/init.d/00-host-hardening-check.sh`) that verifies all of the above on Linux hosts. It warns if anything is missing but **never blocks** stack startup. It is especially useful when onboarding a new LXC or after a host OS upgrade.

Checks performed:
1. Anti-DDoS sysctls (`rmem_max`, `wmem_max`, `netdev_max_backlog`, `tcp_max_syn_backlog`, `nf_conntrack_max`)
2. Installation and status of the CrowdSec Firewall Bouncer service
3. File descriptor limit (`ulimit -n` ≥ 65536)
4. Swap presence (warns if > 0)
5. Docker live-restore configuration
6. `vm.overcommit_memory` value

### CrowdSec Firewall Bouncer (Host-Level Blocking)

The Traefik plugin blocks traffic at Layer 7 (HTTP), which means malicious packets still reach the proxy and consume CPU. For maximum anti-DDoS efficiency, install the **CrowdSec Firewall Bouncer** (`cs-firewall-bouncer`) directly on the Debian host:

```bash
# Install
apt install crowdsec-firewall-bouncer-nftables

# Configure to use the same LAPI
CSCLI_API_URL=http://127.0.0.1:8080  # or CrowdSec container IP if LAPI is exposed
```

This drops packets at **netfilter** (nftables/iptables) *before* they ever touch Docker or Traefik. The container-based plugin remains as a fallback.

### Completed Hardening Checklist

| Change | Status | Files |
|--------|--------|-------|
| Dashboard proxy network isolation (`socket-proxy-dashboard`) | ✅ Done | `docker-compose-dashboard.yaml` |
| Atomic `profiles.yaml` write | ✅ Done | `restart-internal.sh` |
| Atomic bouncer key rotation (add-before-delete) | ✅ Done | `scripts/init.d/06-boot.sh` |
| Regex sanitization for `BLOCKED_PATHS` / `BAD_USER_AGENTS` | ✅ Done | `generate-config.py` |
| Redis isolated from `traefik` network | ✅ Done | `docker-compose-edge.yaml`, `docker-compose-security.yaml` |
| Healthchecks added (`dozzle`, `watchdog`, `maintenance`, `redis-exporter`) | ✅ Done | compose files |
| Watchdog `init: true` (zombie reaping) | ✅ Done | `docker-compose-dashboard.yaml` |
| Robust CSV parsing (multi-line fields, `csv.Error` handling) | ✅ Done | `generate-config.py` |
| Dashboard isolated from host Docker socket (dedicated proxy) | ✅ Done | `docker-compose-dashboard.yaml`, `utils/system.py` |
| Buffer size limits (50 MB default) | ✅ Done | `generate-config.py`, `.env.dist` |
| WriteTimeout aligned with ReadTimeout | ✅ Done | `traefik.yaml.template` |
| Bearer auth on Prometheus remote_write | ✅ Done | `docker-compose-observability.yaml`, `config.alloy`, `.env.dist` |
| maxConnsPerHost limit (500) | ✅ Done | `generate-config.py`, `.env.dist` |
| Global circuit breaker | ✅ Done | `generate-config.py` |
| Retry middleware (2 attempts) | ✅ Done | `generate-config.py` |
| no-new-privileges on maintenance and alloy | ✅ Done | compose files |
| Alloy healthcheck | ✅ Done | `docker-compose-observability.yaml` |
| Valkey maxmemory increased to 512 MB | ✅ Done | `config/valkey/valkey.conf` |
| DDoS detection alerts (Grafana + Prometheus) | ✅ Done | `rules.yaml`, `rules.yml` |
| TLS cipher suites delegated to Go defaults | ✅ Done | `traefik.yaml.template` |
| Generous rate limit for static assets | ✅ Done | `generate-config.py` |
| Loki compaction interval tuned for slow disks | ✅ Done | `config/loki/config.yaml` |
| Dashboard healthcheck endpoint (`/healthz`) | ✅ Done | `views.py`, `docker-compose-dashboard.yaml` |
| Host hardening pre-flight check | ✅ Done | `scripts/init.d/00-host-hardening-check.sh` |

---

## 7. TL;DR — Quick Reference

### Important Environment Variables

| Variable | Impact if wrong |
|----------|-----------------|
| `DOMAIN` | Breaks all dashboard URLs and watchdog alerts |
| `TRAEFIK_ACME_ENV_TYPE` | Wrong type = staging certs in production (browser warnings) or production certs during testing (rate limit hits) |
| `CROWDSEC_ENABLE` | `false` removes the firewall entirely — only valid for temporary debugging |
| `CROWDSEC_APPSEC_ENABLE` | `false` disables the Layer-7 WAF; AppSec collections are not loaded |
| `TRAEFIK_HSTS_MAX_AGE` | High value + no HTTPS = users blocked from the domain for up to 1 year |
| `TRAEFIK_TIMEOUT_ACTIVE` | Too low = legitimate slow requests time out; too high = opens DoS vector |
| `PROMETHEUS_RETENTION_DAYS` | Very high values + low `PROMETHEUS_MEM_LIMIT` = OOM kills |
| `BACKREST_ENABLE` | `false` disables Backrest entirely — the compose file is not loaded |
| `BACKREST_PROJECTS_DIR` | Must point to the parent directory of all Docker projects on this LXC |

Variables managed automatically by `start.sh` — **never suggest editing them manually**:
- `TRAEFIK_CERT_RESOLVER`
- `DASHBOARD_APP_PATH_HOST`
- `DASHBOARD_SECRET_KEY`
- `CROWDSEC_WEB_UI_PASSWORD`
- `CROWDSEC_DB_PASSWORD`
- `CROWDSEC_LAPI_KEY`
- `REDIS_PASSWORD`
- `ANUBIS_REDIS_PRIVATE_KEY`
- `PROMETHEUS_REMOTE_WRITE_TOKEN`
- `TRAEFIK_DASHBOARD_AUTH`
- `DOZZLE_DASHBOARD_AUTH`

### Generated Files (DO NOT TOUCH)

- `config/traefik/dynamic-config/*`
- `config/traefik/traefik-generated.yaml`
- `config/crowdsec/acquis.yaml`
- `config/crowdsec/profiles.yaml`
- `docker-compose-anubis-generated.yaml`

### Essential Make Commands

```bash
make start       # Full startup
make stop        # Graceful shutdown
make restart     # Full restart
make validate    # Validate .env
make health      # Health diagnostics
make help        # Full list
```

### Future Architecture Considerations

- **Mixed ACME Challenges**: Currently, all domains default to Let's Encrypt `tlsChallenge`. In the future, we may need to implement `httpChallenge` and `dnsChallenge` alongside `tlsChallenge` to handle domains with different configurations.
  - *Note*: This will require adding a new column to `domains.csv` to specify the challenge type per domain, which in turn will require updating the Domain Manager in the Flask Dashboard UI to parse and manage this new field.

---

Happy coding. Keep this stack bulletproof.
