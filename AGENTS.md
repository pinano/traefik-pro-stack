# AGENTS.md — Project Context & Guidelines for AI Assistants

Welcome, fellow agent. This document is your single source of truth for understanding the stack, how it's structured, and how the user expects things to be done. Read it before touching anything.

---

## Project Essence

This is a **self-hosted, production-grade infrastructure stack** designed for high-availability, defense-in-depth security, and deep observability. It is not a toy setup — it runs real domains, handles real threats, and is expected to behave reliably under pressure.

The core mission: protect multiple Docker-based web applications (and optionally, legacy Apache/PHP services running on the host) with a fully automated, zero-config-drift anti-DDoS and anti-bot system.

---

## The Tech Stack

| Layer | Component | Role |
|-------|-----------|------|
| **Edge Router** | Traefik v3.x | TLS termination, middleware chain, dynamic routing |
| **IPS** | CrowdSec | Collaborative IP reputation, behavioral detection |
| **WAF** | CrowdSec AppSec | Layer-7 payload inspection (OWASP rules, virtual patches) |
| **Bot Defense** | Anubis | Proof-of-Work challenge via ForwardAuth |
| **Session Cache** | Redis / Valkey | Anubis PoW sessions + CrowdSec ban cache |
| **Log Aggregation** | Loki | Stores and indexes container logs |
| **Metrics** | Prometheus | Time-series metrics from all services |
| **Collection** | Grafana Alloy | Discovers containers, ships logs to Loki, metrics to Prometheus |
| **Visualization** | Grafana | Dashboards + Managed Alerting |
| **Admin UI** | Dashboard | Flask/Python UI to manage `domains.csv` + SSO provider |
| **Security UI** | CrowdSec Web UI | Web interface for LAPI alert management and decision overview |
| **Monitor** | Watchdog | Checks SSL expiry, DNS records, CrowdSec health → Telegram |
| **Orchestration** | Docker Compose | Modular multi-file compose structure |
| **Automation** | Python + Bash | Config generation, environment management, cert tools |

---

## Repository Layout

```
.
├── .env.dist                              # Environment variables template
├── .env                                   # Your local config (git-ignored)
├── domains.csv.dist                       # Domain inventory template
├── domains.csv                            # Your domains config (git-ignored)
├── Makefile                               # Project management commands
│
├── scripts/                               # Core automation scripts
│   ├── backup.sh                          # Configuration and data backup script
│   ├── compose-files.sh                   # Shared compose file list builder (single source of truth)
│   ├── create-local-certs.sh              # Local mkcert certificate generator
│   ├── crowdsec-geoblock.sh               # CrowdSec country banning/unbanning utility
│   ├── generate-config.py                 # Dynamic Traefik config generator (from domains.csv)
│   ├── health.sh                          # Global stack health check utility
│   ├── initialize-env.sh                  # Interactive .env setup wizard
│   ├── inspect-certs.py                   # Certificate inspection utility
│   ├── maintenance.sh                     # Global maintenance mode toggler
│   ├── prune-certs.py                     # Orphaned certificate cleanup utility
│   ├── release.sh                         # Versioning: Creates new releases and tags
│   ├── requirements.txt                   # Python dependencies (tldextract, pyyaml)
│   ├── restart-internal.sh                # Script triggered by Dashboard to hot-reload stack
│   ├── restore.sh                         # Configuration and data restore script
│   ├── rollback.sh                        # Versioning: Rollback to previous version tag
│   ├── setup-grafana-alerting.sh          # Grafana Alerting API configuration (auto-called on start)
│   ├── start.sh                           # Full stack startup orchestrator (6 phases)
│   ├── stop.sh                            # Graceful stack shutdown
│   ├── update.sh                          # Versioning: Safe upgrade to latest release
│   ├── validate-env.py                    # .env validation & sync tool
│   └── make/                              # Conditional Makefile includes
│       ├── certs.mk                       # Local cert targets (included only if TRAEFIK_ACME_ENV_TYPE=local)
│       ├── crowdsec.mk                    # CrowdSec management targets (included if CrowdSec enabled)
│       └── grafana.mk                     # Grafana alerting setup targets
│
├── config/
│   ├── traefik/
│   │   ├── traefik.yaml.template          # Static config template (processed by start.sh)
│   │   ├── traefik-generated.yaml         # Generated static config (do not edit)
│   │   ├── acme.json                      # Let's Encrypt certificate storage (mode 600, git-ignored)
│   │   ├── certs-local-dev/               # mkcert certificates for local mode
│   │   └── dynamic-config/               # Generated routers/middlewares (from generate-config.py)
│   │
│   ├── crowdsec/
│   │   ├── acquis-base.yaml              # Base log acquisition config (Traefik + SFTP)
│   │   ├── acquis.yaml                   # Generated acquisition config (AppSec block auto-appended)
│   │   ├── profiles.yaml                 # Custom ban profiles (7d repeat, 24h standard, 48h range)
│   │   ├── captcha_keys.csv              # CAPTCHA credentials registry (git-ignored)
│   │   ├── parsers/                      # Custom parsers (IP whitelist auto-generated by start.sh)
│   │   └── scenarios/                    # Custom detection scenarios
│   │
│   ├── anubis/
│   │   ├── botPolicy.yaml                # Bot challenge policy (allow/deny/challenge rules)
│   │   └── assets/                       # Anubis challenge page assets
│   │       ├── custom.css.dist           # Default stylesheet template
│   │       └── static/img/               # Challenge page images (.dist versions)
│   │
│   ├── crowdsec-web-ui/                  # Data directory for CrowdSec LAPI interface
│   ├── dashboard/                        # Admin UI backend (Python/Flask)
│   │   ├── app.py                        # Flask application
│   │   ├── Dockerfile
│   │   ├── static/                       # Frontend assets
│   │   └── templates/                    # HTML templates
│   │
│   ├── maintenance/
│   │   └── index.html                    # Premium HTML page for maintenance mode
│   │
│   ├── grafana/
│   │   ├── dashboards/                   # Pre-built JSON dashboards (Traefik, CrowdSec, Redis, Node)
│   │   └── provisioning/
│   │       ├── datasources/datasources.yaml  # Prometheus + Loki datasource definitions
│   │       ├── dashboards/dashboards.yaml    # Dashboard folder loader config
│   │       └── alerting/
│   │           ├── rules.yaml            # 13 alert rules (infrastructure, HTTP, host, Redis)
│   │           ├── contact-points.yaml   # Placeholder (contact point created via API at startup)
│   │           └── notification-policies.yaml  # Placeholder (policy created via API at startup)
│   │
│   ├── loki/config.yaml                  # Loki storage and ingestion config
│   ├── prometheus/
│   │   ├── prometheus.yml                # Scrape configs and remote_write receiver
│   │   └── rules.yml                     # Prometheus recording/alerting rules (mirrors Grafana rules)
│   ├── redis/redis.conf                  # Valkey/Redis config (allkeys-lru, no persistence)
│   ├── alloy/config.alloy               # Alloy collector config (log discovery, metric scraping)
│   └── watchdog/
│       ├── Dockerfile
│       ├── check-certs.sh               # Certificate expiration checker
│       ├── check-crowdsec.sh            # CrowdSec health monitor
│       ├── check-dns.sh                 # DNS resolution verifier
│       ├── check-system.sh              # Host and container resources monitor
│       └── check-traefik.sh             # Traefik routing config health monitor
│
└── Docker Compose Files:
    ├── docker-compose-edge.yaml              # Edge: Traefik (TLS termination, routing)
    ├── docker-compose-security.yaml          # Security: CrowdSec, Redis, Redis Exporter, CrowdSec Web UI
    ├── docker-compose-observability.yaml     # Observability: Grafana, Loki, Alloy, Prometheus
    ├── docker-compose-dashboard.yaml         # Dashboard: Dashboard, Dozzle, Watchdog, ctop
    ├── docker-compose-anubis.yaml            # Bot Defense: Anubis base template + Assets server
    ├── docker-compose-anubis-generated.yaml  # Auto-generated Anubis instances (per TLD, do not edit)
    ├── docker-compose-maintenance.yaml       # Maintenance: Global 503 fallback container
    └── docker-compose-apache-logs.yaml       # Apache log extension (auto-included if Apache detected)
```

---

## How the Stack Boots (`start.sh`)

Understanding the startup sequence is critical before suggesting any changes:

1. **Env sync**: Merges `.env.dist` structure with existing `.env` values; backs up `.env` to `.env.bak`. Never destructive.
2. **Credential sync**: Auto-generates `DASHBOARD_SECRET_KEY` if missing. Detects and regenerates changed admin passwords into bcrypt hashes. Updates `TRAEFIK_CERT_RESOLVER` based on `TRAEFIK_ACME_ENV_TYPE`.
3. **Asset prep**: Copies `.dist` Anubis assets if no custom overrides exist. Generates `traefik-generated.yaml` from `traefik.yaml.template` via `sed` substitution. Runs `generate-config.py` to produce all dynamic Traefik config.
4. **Network + security prep**: Creates Docker networks (`traefik`, `anubis-backend`). Generates CrowdSec IP whitelist file. Probes for host Apache via TCP socket.
5. **Security-first boot**: CrowdSec and Redis boot first. Health check loop (60s timeout). Traefik is not started until CrowdSec health check passes. Bouncer key is registered/re-registered every time.
6. **Full stack start**: All remaining services launch. `grafana-setup-telegram` is called automatically.

**Key invariant**: the script is idempotent — running it multiple times against an already-running stack does minimal work and avoids container recreations.

---

## Configuration Architecture

### Dynamic Config Generation

Traefik's dynamic routing config is **entirely generated** — never hand-edited:

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

If you need to add a Traefik middleware, router, or service that isn't driven by `domains.csv`, add it either:
- As a Docker label on the relevant container, or
- As a new template/logic in `generate-config.py`.

**Do not** create static YAML files in `dynamic-config/` by hand — they will be overwritten or conflicted by the next `make start`.

### Compose File Modularity

The stack uses multiple compose files to keep concerns separated:

| File | Contents |
|------|----------|
| `docker-compose-edge.yaml` | Traefik |
| `docker-compose-security.yaml` | CrowdSec, Redis, Redis Exporter, CrowdSec Web UI |
| `docker-compose-observability.yaml` | Grafana, Loki, Alloy, Prometheus |
| `docker-compose-dashboard.yaml` | Dashboard (Flask), Dozzle, Watchdog, ctop |
| `docker-compose-anubis.yaml` | Anubis base template + Anubis Assets server |
| `docker-compose-anubis-generated.yaml` | Auto-generated Anubis instances (from `generate-config.py`) |
| `docker-compose-apache-logs.yaml` | Apache log integration (auto-included only when Apache is detected) |

The active compose file list is determined by `scripts/compose-files.sh` — the **single source of truth** used by both `start.sh`, `stop.sh`, and the `Makefile`. Never hard-code compose file lists elsewhere.

### CrowdSec Dynamic Configurations

`config/crowdsec/acquis.yaml` is generated by `start.sh` from `acquis-base.yaml`. When `CROWDSEC_APPSEC_ENABLE=true`, the AppSec listener block is automatically appended and the AppSec collections are injected into `CROWDSEC_COLLECTIONS`.

Similarly, `config/crowdsec/profiles.yaml` is generated from `profiles-base.yaml`. The CAPTCHA remediation profile is conditionally injected only if there are active configurations in the CAPTCHA registry (`config/crowdsec/captcha_keys.csv`).

Do not edit `acquis.yaml` or `profiles.yaml` directly — edit their respective `-base.yaml` files instead.

---

## Security Model

### Middleware Chain Order

```
Request → [UA Blacklist Router] → (if matched: 403)
       → [CrowdSec Bouncer] → (if banned IP or bad payload: 403; if captcha: present challenge)
       → [Slowloris Buffer]
       → [Security Headers]
       → [Rate Limiter]
       → [Concurrency Limiter]
       → [ForwardAuth / Anubis] → (if no valid cookie: PoW challenge)
       → [Compression]
       → Backend
```

The **UA Blacklist** is a separate high-priority router, not part of the middleware chain. Changes to this chain require modifying `generate-config.py`.

### Network Isolation

Two Docker networks:
- **`traefik`** (external, bridged): All services that need Traefik to route to them.
- **`anubis-backend`** (internal, no egress): Only Redis and Anubis instances. Anubis can talk to Redis but cannot make outbound internet connections.

### Fail-Open by Design

The CrowdSec bouncer is configured fail-open:
- If LAPI is unreachable: traffic passes through.
- If AppSec is unreachable: traffic passes through.
- If Redis cache is down: traffic passes through.

This prioritizes availability over security under fault conditions, which is appropriate for a general-purpose stack. If a Fail Closed posture is needed, it must be changed explicitly in `traefik.yaml.template`.

### Automatic Secret Management

Do not prompt the user to generate secrets manually. `start.sh` auto-generates:
- `DASHBOARD_SECRET_KEY` (Flask session key)
- `CROWDSEC_API_KEY` (bouncer auth) — via `make init`
- `ANUBIS_REDIS_PRIVATE_KEY` — via `make init`
- `REDIS_PASSWORD` — via `make init`
- Dashboard auth hashes (bcrypt via `htpasswd`)

---

## Environment Variables — What Matters

Key variables an agent must understand before making changes:

| Variable | Impact if wrong |
|----------|----------------|
| `DOMAIN` | Breaks all dashboard URLs and watchdog alerts |
| `TRAEFIK_ACME_ENV_TYPE` | Wrong type = staging certs in production (browser warnings) or production certs during testing (rate limit hits) |
| `CROWDSEC_ENABLE` | `false` removes the firewall entirely — valid for debugging only |
| `CROWDSEC_APPSEC_ENABLE` | `false` disables Layer-7 WAF; AppSec collections are not loaded |
| `TRAEFIK_HSTS_MAX_AGE` | High value + no HTTPS = users locked out of the domain for up to 1 year |
| `TRAEFIK_TIMEOUT_ACTIVE` | Too low = legitimate slow requests time out; too high = opens DoS vector |
| `PROMETHEUS_RETENTION_DAYS` | Very high values + low `PROMETHEUS_MEM_LIMIT` = OOM kills |

Variables managed automatically by `start.sh` — **never suggest editing these manually**:
- `TRAEFIK_CERT_RESOLVER`
- `DASHBOARD_APP_PATH_HOST`
- `DASHBOARD_SECRET_KEY`
- `CROWDSEC_WEB_UI_PASSWORD`
- `CROWDSEC_API_KEY`
- `REDIS_PASSWORD`
- `ANUBIS_REDIS_PRIVATE_KEY`
- `TRAEFIK_DASHBOARD_AUTH`
- `DOZZLE_DASHBOARD_AUTH`

---

## Coding & Change Guidelines

### 1. Be Concise & Colloquial
No corporate fluff. Speak clearly and get to the point. A natural tone is fine.

### 2. Solidity First
Every change must prioritize security, performance, and robustness over convenience. "Quick but dirty" is wrong here. Edge cases matter. Error handling must be graceful.

### 3. No Hallucinations
If you're unsure about a Traefik middleware option, a CrowdSec scenario name, or a Grafana API endpoint — **look it up**. The official docs are:
- Traefik: https://doc.traefik.io/traefik/
- CrowdSec: https://docs.crowdsec.net/
- Anubis: https://anubis.techaro.lol/docs/
- Grafana Alerting API: https://grafana.com/docs/grafana/latest/developers/http_api/alerting_provisioning/

### 4. Executive Summaries
When explaining or proposing changes, lead with **why** and **what** before diving into **how**.

### 5. Check Before Reinventing
- Check the `Makefile` — most day-to-day operations already have a target.
- Check `scripts/` — most automation is already scripted.
- Check `generate-config.py` — adding a new Traefik config pattern probably means adding a template there.

### 6. Respect Modularity
- Don't add services to existing compose files if a new dedicated file makes more sense.
- Don't add Traefik router/middleware config to compose files for services that already have it handled by `generate-config.py`.
- `compose-files.sh` is the single source of truth for which files are active. Keep it updated if you add a new compose file.

### 7. Generated Files Are Off-Limits
Do not propose editing these directly — they are overwritten at every start:
- `config/traefik/dynamic-config/*`
- `config/traefik/traefik-generated.yaml`
- `config/crowdsec/acquis.yaml`
- `config/crowdsec/profiles.yaml`
- `docker-compose-anubis-generated.yaml`

If a change is needed in any of these, modify the **template or generator** instead.

### 8. Security Is Always on the Menu
If you spot a hardening opportunity while working on something else — mention it. Don't implement it silently, but do flag it.

---

## Key Operational Commands

Agents should use these rather than raw `docker compose` calls:

```bash
make start            # Full boot sequence (generates config, waits for health, etc.)
make stop             # Graceful shutdown
make restart          # Full stop + start
make restart traefik  # Restart single service
make rebuild          # Rebuild dashboard and watchdog images
make logs traefik     # Follow logs for a service
make shell crowdsec   # Open shell in container
make validate         # Check .env for errors
make crowdsec-decisions  # List active bans
make crowdsec-unban 1.2.3.4
make certs-info       # Certificate status overview
make help             # Full command list
```

---

## Common Pitfall Patterns

| Pitfall | Correct approach |
|---------|-----------------|
| Editing `dynamic-config/` directly | Edit `generate-config.py` or use Docker labels |
| Adding global Traefik config to compose labels | Edit `traefik.yaml.template` for static config |
| Hard-coding compose file lists | Use / update `compose-files.sh` |
| Suggesting `CROWDSEC_ENABLE=false` as a permanent fix | It disables the firewall. Only valid for temporary debugging. |
| Forgetting `apache-host` requires Apache actually running | The TCP probe at startup determines if it's included |
| Changing `TRAEFIK_HSTS_MAX_AGE` to a high value without testing HTTPS first | Always test with a low value (300) first |
| Creating new secrets manually and adding them to .env | Use `openssl rand -hex 32` and update via `make init` or the auto-sync in `start.sh` |
| Forgetting to add a domain to the Turnstile widget configuration | The CAPTCHA will fail to load on that domain, acting as an un-solvable ban for affected users. |
| "Fixing" the `chmod 777` fallback in `start.sh` for `./data` | It is intentional. Without `sudo`, `chown 472:472` fails. 777 ensures non-root containers (Grafana/Loki) can write. Do not change it to 775. |

---

Happy coding. Keep this stack bulletproof.
