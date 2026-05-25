<div align="center">

<img src="config/dashboard/static/favicon.webp" alt="Traefik Pro Stack Mission Badge" width="220">

# Traefik Pro Stack

**Your web. Locked down, lit up, production-ready.**

*Traefik + CrowdSec + Anubis + Grafana · Full-stack anti-DDoS & anti-bot infrastructure for multi-domain Docker environments.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Traefik](https://img.shields.io/badge/Traefik-v3.x-informational?logo=traefikproxy)](https://doc.traefik.io/traefik/)
[![CrowdSec](https://img.shields.io/badge/CrowdSec-enabled-success?logo=crowdsec)](https://crowdsec.net)
[![Anubis](https://img.shields.io/badge/Anubis-Bot_Defense-8a2be2)](https://anubis.techaro.lol/docs/)
[![Grafana](https://img.shields.io/badge/Grafana-Observability-orange?logo=grafana)](https://grafana.com)
[![Prometheus](https://img.shields.io/badge/Prometheus-Metrics-e6522c?logo=prometheus)](https://prometheus.io)
[![Redis](https://img.shields.io/badge/Redis-Cache-dc382d?logo=redis)](https://redis.io)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue?logo=docker)](https://docs.docker.com/compose/)

</div>

---

## Table of Contents
1. [Overview and Core Capabilities](#overview-and-core-capabilities)
2. [System Architecture and Component Design](#system-architecture-and-component-design)
3. [Prerequisites and System Preparation](#prerequisites-and-system-preparation)
4. [Step-by-Step Quick Start Guide](#step-by-step-quick-start-guide)
5. [Comprehensive Repository Layout](#comprehensive-repository-layout)
6. [Security Model and Border Middleware Flow](#security-model-and-border-middleware-flow)
7. [CrowdSec AppSec WAF Architecture and Rules](#crowdsec-appsec-waf-architecture-and-rules)
8. [Operational Automation Scripts](#operational-automation-scripts)
9. [Detailed Environment Variables Configuration](#detailed-environment-variables-configuration)
10. [Domain Routing Inventory Design](#domain-routing-inventory-design)
11. [Makefile Administration Command Registry](#makefile-administration-command-registry)
12. [Special Operational Modes](#special-operational-modes)
13. [FAQ and Operational Troubleshooting](#faq-and-operational-troubleshooting)
14. [License](#license)

---

## Overview and Core Capabilities

The Traefik Pro Stack is an integrated, self-hosted, and production-grade edge gateway infrastructure designed to provide defense-in-depth security, mitigation of automated attacks, and comprehensive system visibility. Optimized for multi-domain Docker environments, it routes, secures, and monitors traffic directed to containerized web applications as well as legacy non-containerized services running on the host network.

Instead of relying on basic reverse proxies that require manually maintained configuration files and static certificates, this stack uses dynamic configuration generation driven by a simple domain inventory. It binds edge-routing routing logic directly to an active intrusion prevention system (IPS), a web application firewall (WAF), a proof-of-work (PoW) bot-challenge mechanism, and a modern telemetry pipeline.

### Core Strengths

*   **Border Routing and Automatic TLS**: Driven by Traefik v3.x, the stack handles HTTP, HTTPS, and HTTP/3 (QUIC) connections. It automatically negotiates and renews Let's Encrypt certificates, organizing domains dynamically into optimal groupings to prevent rate limit penalties. It also features a fully local developer mode using trust-injected self-signed certificates.
*   **Behavioral Intrusion Prevention and WAF**: Powered by CrowdSec IPS and CrowdSec AppSec. The security engine continuously analyzes logs from all services to identify and block scanning tools, brute-force attempts, and anomalous behavior. The Layer-7 AppSec engine acts as an inline WAF, intercepting payloads to block common web application attacks such as SQL injection (SQLi), Cross-Site Scripting (XSS), and Remote Code Execution (RCE) using standard OWASP Rulesets.
*   **Cryptographic Challenge Mitigation**: Integrating the Anubis Proof-of-Work engine. When a domain is protected, unauthenticated web browsers are presented with a lightweight cryptographic puzzle. Resolving this puzzle requires a brief computing effort on the client-side (typically 1 to 3 seconds), verifying that the user is operating a standard browser rather than a scraper or headless bot. Successful verification issues a token signed with an Ed25519 private key, granting access for a configurable timeframe.
*   **Single Sign-On and Access Control**: A centralized Python/Flask administrative dashboard allows you to manage routing settings, inspect certificate health, and oversee captcha keys. This dashboard integrates directly into Traefik using its ForwardAuth middleware to serve as a Single Sign-On (SSO) gateway, protecting administrative interfaces (Dozzle logs, Traefik's internal API dashboard, Grafana, and the CrowdSec LAPI console) behind a unified, session-secured portal.
*   **Observability Pipeline**: Telemetry is structured via Grafana Alloy, Loki, Prometheus, and Grafana. Alloy discovers running containers, parses access logs, and scrapes Prometheus endpoints. Logs are shipped to Loki and metrics to Prometheus, feeding pre-configured Grafana dashboards that display security statistics, system resources, and request routing anomalies.
*   **System Watchdog**: An isolated background daemon monitors certificate lifetimes, domain DNS resolutions, host hardware metrics (CPU, memory, disk, and IO), and Traefik dynamic configuration drift. Any anomalies trigger notifications dispatched directly to a Telegram group.
*   **Fail-Open Border Resilience**: To prevent operational downtime, the CrowdSec integration is configured as fail-open. If the security database, the WAF listener, or the session cache goes offline, edge traffic is permitted to flow through rather than being dropped, maintaining availability under anomalous conditions.

---

## System Architecture and Component Design

The stack relies on network segregation and credential isolation. Containers are mapped to specific Docker networks depending on their security profiles and data requirements.

### Network Topologies

1.  **The traefik Network (External/Bridged)**: This is the primary edge routing network. It connects the Traefik proxy container to all backend applications that require public routing. It also contains the admin dashboard, the observability suite (Alloy, Prometheus, Loki, Grafana), and the CrowdSec firewall agent.
2.  **The anubis-backend Network (Internal/No Egress)**: This is a hardened, isolated network. It connects Anubis challenge verification servers to a dedicated Redis/Valkey cache database. To limit the attack surface, this network is completely internal, meaning no container attached to it can initiate outbound connections to the host or the public internet. It exists solely to perform session cache lookups and validate proof-of-work challenges.

### Component Inter-Connectivity Model

```mermaid
flowchart TD
    subgraph traefik_network ["External Network: traefik"]
        Traefik[Traefik Edge Router]
        Dashboard[Admin Dashboard / SSO Flask]
        CrowdSec[CrowdSec LAPI / AppSec WAF]
        Redis[Valkey / Redis Cache]
        Dozzle[Dozzle Log Viewer]
        Alloy[Grafana Alloy Collector]
        Prometheus[Prometheus Metrics]
        Loki[Loki Log Storage]
        Grafana[Grafana Dashboards & Alerts]
        Watchdog[Watchdog Monitor]
    end
    
    subgraph anubis_network ["Internal Network: anubis-backend"]
        Anubis1[Anubis Instance 1]
        Anubis2[Anubis Instance 2]
        RedisInternal[Valkey / Redis Cache]
    end

    Internet[Internet / Public Clients] -->|Ports 80, 443| Traefik
    Traefik <-->|SSO Auth Check| Dashboard
    Traefik <-->|AppSec WAF / LAPI Check| CrowdSec
    CrowdSec <-->|Bans Cache DB 0| Redis
    Traefik <-->|ForwardAuth PoW Check| Anubis1
    Anubis1 <-->|PoW Sessions DB 1| RedisInternal
    
    Alloy -->|Logs Scraping| Loki
    Alloy -->|Metrics Scraping| Prometheus
    Prometheus --> Grafana
    Loki --> Grafana
    
    Watchdog -->|System Health Alerts| Telegram[Telegram Bot API]
    Grafana -->|Metrics Alerts| Telegram
```

In this layout, the client's request enters Traefik via ports 80 or 443. Traefik coordinates with the CrowdSec container (via a custom plugin) and the Anubis instances (via ForwardAuth headers) to evaluate the request. Once verified, the request is routed either to a container on the traefik network or to the host loopback gateway if it is pointing to a legacy non-containerized application.

### Watchdog Diagnostics Subsystem

The Watchdog service runs as a decoupled daemon container. Rather than running a monolithic checking process, it initializes multiple sub-shells running in parallel at different sleep intervals, reporting failures via Telegram:

```mermaid
flowchart TD
    Watchdog[Watchdog Container] --> CertCheck[check-certs.sh - Every 24h]
    Watchdog --> DNSCheck[check-dns.sh - Every 6h]
    Watchdog --> CSCheck[check-crowdsec.sh - Every 1h]
    Watchdog --> SysCheck[check-system.sh - Every 5m]
    Watchdog --> TraefikCheck[check-traefik.sh - Every 5m]
    CertCheck -->|Expiry Warning| Telegram[Telegram Bot API]
    DNSCheck -->|DNS Shift Warning| Telegram
    CSCheck -->|LAPI Failure Warning| Telegram
    SysCheck -->|Hardware Overload Warning| Telegram
    TraefikCheck -->|Router Drift Warning| Telegram
```

---

## Prerequisites and System Preparation

Deploying the stack requires preparing the host system's kernel, network bindings, and directory permissions.

### Host Specifications

1.  **Operating System**: Linux kernel v4.15 or later. The kernel must have support for `sysctl` overrides (such as `net.core.somaxconn` and `net.ipv4.tcp_syncookies`) to handle high connection spikes and mitigate SYN flood attempts at the networking layer.
2.  **Docker Runtime**: Docker Engine v24.0.0 or later. Docker must be configured to run as a systemd service, and the docker daemon socket (`/var/run/docker.sock`) must be accessible to the deploying user (or accessible via sudo).
3.  **Compose Plugin**: Docker Compose v2.20.0 or later (invoked as `docker compose`). Legacy versions (Compose V1, `docker-compose`) are not compatible due to the modular config features utilized.
4.  **Python Environment**: Python 3.8 or later, including the `venv` and `pip` packages. This environment is used to run local configuration generation scripts, perform environment variable validations, and inspect local certificates.
5.  **Network Socket Allocation**: Ports `80` (HTTP) and `443` (HTTPS/UDP for HTTP/3-QUIC) must be completely open and unallocated on all host interfaces. If another web server (such as standalone Nginx or Apache) is running on the host, it must be stopped or bound to a different port.
6.  **Loopback Redirection (Optional)**: If you plan to route requests to a legacy non-containerized service running on the host, the host firewall must permit connections on the Docker interface gateway (usually `172.17.0.1` or `172.16.0.1`) on the target port (e.g., `8080`).

---

## Step-by-Step Quick Start Guide

### Step 1: Initialize the Environment

Before bringing up the container stack, initialize the localized environment configurations. Run the following command from the repository root:

```bash
make init
```

This target launches an interactive configuration wizard (`scripts/initialize-env.sh`) that performs the following tasks:
1.  Verifies the presence of Python 3 and creates an isolated virtual environment (`.venv`).
2.  Installs the necessary requirements (such as `pyyaml` and `tldextract`) inside the virtual environment.
3.  Creates your local `.env` configuration file from the template (`.env.dist`).
4.  Prompts you for essential parameters (primary domain name, timezone, SSL registration email, and administrator credentials).
5.  Generates secure cryptographic keys using `openssl` for the Flask dashboard secret key, the Redis database password, the Anubis token signing key, and the CrowdSec API bouncer key.

### Step 2: Customize Environment Variables

Open the generated `.env` file in a text editor to verify the settings. Pay attention to:
*   `DOMAIN`: Set this to your primary root domain (e.g., `company.com`).
*   `TRAEFIK_ACME_ENV_TYPE`: Set this to `staging` during initial setup. Staging requests certificates from Let's Encrypt's staging authority, which does not enforce strict rate-limiting rules. Once you verify that routing and certificate negotiation succeed, change this value to `production` and restart the stack to acquire trusted certificates.
*   `TRAEFIK_ACME_EMAIL`: Ensure this email is valid, as Let's Encrypt uses it to deliver expiration alerts.

### Step 3: Populate the Domain Inventory

Open the `domains.csv` file. This inventory file acts as the single source of truth for routing. Add a line for each subdomain or domain you wish to expose:

```csv
# domain, redirection, docker_service, anubis_subdomain, rate, burst, concurrency
company.com, , landing-web, , , ,
www.company.com, company.com, landing-web, , , ,
crm.company.com, , crm-app, auth, 40, 80, 20
```

For each domain:
*   Define the FQDN (`domain`).
*   Configure optional redirect rules (`redirection`).
*   Set the backend Docker container name (`docker_service`).
*   Configure the Anubis PoW subdomain (`anubis_subdomain`) to enable cryptographic challenge protection on that route.
*   Define custom rate-limiting rules (`rate`, `burst`, `concurrency`) if the global defaults are not appropriate.

### Step 4: Launch the Stack

Run the startup target:

```bash
make start
```

This script executes the startup orchestrator (`scripts/start.sh`), which processes configurations in six phases:
1.  **Validation**: Validates the `.env` file and alerts you to any syntax issues or insecure passwords.
2.  **Configuration Sychronization**: Compiles the final static configuration file for Traefik (`traefik-generated.yaml`) and the static configuration for Valkey/Redis (`redis-generated.conf`).
3.  **Config Generation**: Executes the configuration script (`scripts/generate-config.py`), reading `domains.csv` to generate Traefik dynamic routers (`routers-generated.yaml`) and the dynamic Compose file containing the required Anubis instances (`docker-compose-anubis-generated.yaml`).
4.  **Network Setup**: Verifies that the required Docker bridge networks exist, and compiles the CrowdSec IP whitelist parser from your configured safe IPs.
5.  **Security Bootstrap**: Boots Redis and CrowdSec first. It holds the deployment pipeline until CrowdSec passes its health check, ensuring that no unprotected routing goes live.
6.  **Core Deployment**: Launches the remaining containers (Traefik, Grafana suite, Watchdog, and backend applications) and registers the api bouncers in the local CrowdSec database.

### Step 5: Validate System Health

Once the deployment concludes, run the diagnostics check:

```bash
make health
```

This command queries the status of core APIs and confirms that permissions on sensitive files (such as `.env` and `acme.json`) are set to read-only for their respective processes.

---

## Comprehensive Repository Layout

This section details the layout of the project, including configuration files, templates, and orchestration scripts.

```
.
├── .env.dist                              # Master template for environment configuration variables
├── .env                                   # Local configuration file (git-ignored)
├── domains.csv.dist                       # Master template for domain routing rules
├── domains.csv                            # Active domain routing settings (git-ignored)
├── Makefile                               # System management command wrapper
├── VERSION                                # Current CalVer release tag (e.g. 2026.05.25)
│
├── scripts/                               # Automation and health verification scripts
│   ├── backup.sh                          # Creates timestamped configuration backups
│   ├── compose-files.sh                   # Builds the active Compose file list dynamically
│   ├── create-local-certs.sh              # Automates self-signed CA and certificate generation
│   ├── crowdsec-geoblock.sh               # Downloads CIDR blocks to block geo-specific traffic
│   ├── generate-config.py                 # Core compiler translating domains.csv into routing rules
│   ├── health.sh                          # Runs diagnostics on containers, APIs, and file systems
│   ├── initialize-env.sh                  # Interactive setup wizard for initializing .env
│   ├── inspect-certs.py                   # Reads acme.json to report certificate details
│   ├── maintenance.sh                     # Manages the global maintenance mode container and routing rules
│   ├── prune-certs.py                     # Identifies and removes unused certificate entries
│   ├── release.sh                         # Standardizes new releases by updating changelogs and git tags
│   ├── requirements.txt                   # Local Python package requirements
│   ├── restart-internal.sh                # Executed by Flask UI to perform safe stack reloads
│   ├── restore.sh                         # Restores configuration files from a backup archive
│   ├── rollback.sh                        # Provides interactive checkout to previous git release tags
│   ├── setup-grafana-alerting.sh          # Sets up Grafana's alerting configuration via API
│   ├── start.sh                           # Executes the security-first stack launch pipeline
│   ├── stop.sh                            # Stops containers and tears down network bridges
│   ├── update.sh                          # Safe git checkout pipeline for upgrading production stacks
│   ├── validate-env.py                    # Validates .env files for missing keys and type correctness
│   └── make/                              # Makefile target plugins
│       ├── certs.mk                       # mkcert commands (loaded if TRAEFIK_ACME_ENV_TYPE=local)
│       ├── crowdsec.mk                    # Metrics and ban management targets
│       └── grafana.mk                     # Telegram setup and testing targets
│
├── config/                                # Service-specific configurations and templates
│   ├── traefik/
│   │   ├── traefik.yaml.template          # Static config template processed during startup
│   │   ├── traefik-generated.yaml         # Compiled static configuration (do not edit)
│   │   ├── acme.json                      # Crypted Let's Encrypt certificate vault (perms 600)
│   │   ├── captcha.html                   # HTML template served during CrowdSec CAPTCHA checks
│   │   ├── certs-local-dev/               # Folder storing mkcert developer certificates
│   │   └── dynamic-config/                # Auto-generated routing files from python script
│   │
│   ├── crowdsec/
│   │   ├── acquis-base.yaml              # Static log ingestion source definitions
│   │   ├── acquis.yaml                   # Final compiled log ingestion settings
│   │   ├── config.yaml                   # CrowdSec engine settings
│   │   ├── profiles-base.yaml            # Remediations base profile template
│   │   ├── profiles.yaml                 # Compiled remediation profiles and durations
│   │   ├── captcha_keys.csv              # Registrar mapping domains to captcha keys
│   │   ├── parsers/                      # Custom parsers (contains auto-generated IP whitelists)
│   │   └── scenarios/                    # Custom behavioral detection rules (e.g. rate limit floods)
│   │
│   ├── anubis/
│   │   ├── botPolicy.yaml                # Bot filtering rules (Googlebot whitelist, workers blacklist)
│   │   └── assets/                       # Custom stylesheets and image assets for the PoW screen
│   │
│   ├── dashboard/                        # Flask admin dashboard application
│   │   ├── app.py                        # Server code managing SSO and domains.csv updates
│   │   └── Dockerfile                    # Container build configuration
│   │
│   ├── maintenance/
│   │   └── index.html                    # Offline maintenance page HTML
│   │
│   ├── grafana/
│   │   ├── dashboards/                   # Bundled JSON dashboards
│   │   └── provisioning/                 # Declarative datasource and dashboard allocations
│   │
│   ├── loki/                             # Loki log aggregation configuration
│   ├── prometheus/                       # Prometheus scraper definitions and rules
│   ├── redis/                            # Valkey/Redis cache configuration templates
│   ├── alloy/                            # Grafana Alloy metric and log ingestion pipelines
│   └── watchdog/                         # Watchdog monitor scripts
│
└── docker-compose-*.yaml                  # Modular Compose files divided by service areas
```

---

## Security Model and Border Middleware Flow

To protect backend services, incoming requests must pass through a multi-tier security filter enforced by Traefik's routing engine.

### Border Middleware Sequence

1.  **User-Agent Filtering (Priority 12000)**: Incoming requests are matched against the bad User-Agent regex patterns defined in the environment. Matching requests are immediately dropped with a `403 Forbidden` response at the edge, before invoking any downstream plugins or authorization layers.
2.  **IPS Stream and WAF Inspection (CrowdSec Bouncer)**: The client IP is checked against CrowdSec's memory database (which is synchronized with Redis to ensure low latency). If the IP has been banned, the request is blocked. If the IP requires verification (due to anomalous behavior), they are redirected to a CAPTCHA verification page. Additionally, if AppSec WAF is enabled, the request payload is inspected for malicious patterns (e.g., SQLi, XSS). If a threat is detected, the request is blocked.
3.  **Slowloris Buffer Mitigation**: Requests pass through a buffering middleware that caps the maximum size of request bodies and buffers header blocks in RAM (up to 2MB). This prevents slow-connection attacks (Slowloris) from exhausting Traefik's thread pool.
4.  **Browser Security Header Injection**: Injects standard headers, including HTTP Strict Transport Security (HSTS), frame-ancestor rules to prevent clickjacking, X-Content-Type-Options to block MIME sniffing, and custom Content Security Policies (CSP).
5.  **Rate Limiting**: Checks request frequency against global or domain-specific thresholds. The stack uses a token bucket algorithm to allow temporary bursts while enforcing long-term averages. Requests exceeding these limits are rejected with an HTTP `429 Too Many Requests` code.
6.  **Concurrency Connection Limiting**: Caps the maximum number of simultaneous open TCP sockets allowed per client IP, preventing resource exhaustion on backend applications.
7.  **Bot Challenge Validation (Anubis ForwardAuth)**: Checks for the presence of a valid proof-of-work cookie signed with the stack's private key. If the cookie is missing or invalid, the request is intercepted and redirected to the Anubis challenge portal. Once the client's browser solves the cryptographic puzzle, a signed cookie is issued, and the user is redirected back to the target application.
8.  **Compression and Delivery**: If the client accepts compressed payloads, Traefik applies GZIP compression before delivering the response.

### SSO Forward Authentication Protocol

To protect internal administrative components, the Flask dashboard serves as a ForwardAuth SSO provider. When a user requests an administrative path, the following exchange is executed:

```mermaid
sequenceDiagram
    actor Client as Client / Administrator
    participant Traefik as Traefik Proxy
    participant SSO as Dashboard SSO (/auth-check)
    participant Tool as Secured Tool (e.g. Grafana)
    
    Client->>Traefik: Request /grafana
    Traefik->>SSO: Forward Auth query to dashboard:5000/auth-check
    alt Session Cookie is Valid
        SSO-->>Traefik: HTTP 200 OK + Inject X-Webauth-User & X-Webauth-Role
        Traefik->>Tool: Forward Request with authenticated header extensions
        Tool-->>Client: Serve Tool Workspace (Auto login via Auth Proxy)
    else Session Cookie is Invalid / Missing
        SSO-->>Traefik: HTTP 401 Unauthorized
        Traefik->>Client: Redirect to SSO portal /login page
    end
```

---

## CrowdSec AppSec WAF Architecture and Rules

The CrowdSec AppSec component provides Web Application Firewall (WAF) capabilities inside the edge proxy stack, enabling Layer-7 payload inspection. It is built to block exploitation attempts targeting vulnerabilities such as SQL injection, Cross-Site Scripting, Local/Remote File Inclusion (LFI/RFI), and arbitrary code execution before they reach backend application containers.

### Component Architecture

The WAF operates using a decentralized inspection pipeline:

```
Client Request ──► [ Traefik Proxy ] ──► (Bouncer Plugin)
                                              │
                                              ▼ (HTTP/REST Call)
                                     [ CrowdSec AppSec ] (Port 7422)
                                              │
                                              ├─► Coraza Engine (SecRules CRS)
                                              │
                                              ▼ (Evaluation Output)
Client Request ◄── [ Block 403 / Allow ] ◄────┘
```

1.  **Proxy Payload Forwarding**: The Traefik bouncer plugin intercepts incoming HTTP requests. When AppSec is enabled, the bouncer packages the request headers, parameters, and body, transmitting them via a local HTTP call to the WAF listener running inside the `crowdsec` container on port `7422`.
2.  **Inline Rule Evaluation**: The WAF listener uses Coraza (a high-performance, Go-based, ModSecurity-compatible WAF engine). It evaluates the request details against the active AppSec rulesets.
3.  **Remediation Loop**: If the request matches a malicious pattern:
    *   The AppSec listener returns a block instruction back to the Traefik bouncer plugin.
    *   Traefik immediately halts request execution and serves an HTTP `403 Forbidden` response to the client.
    *   The event is sent to LAPI, creating a security alert and initiating a temporary or permanent IP ban across the stack.

### Rule Ingestion and Configuration

The WAF settings are integrated into the automated startup pipeline:

*   **Dynamic Rule Ingest**: If `CROWDSEC_APPSEC_ENABLE=true` is set in `.env`, the startup script (`start.sh`) modifies `/etc/crowdsec/acquis.yaml` to declare the AppSec listener port `7422` and injects `crowdsecurity/appsec-virtual-patching` and `crowdsecurity/appsec-generic-rules` into the collections registry. This automatically pulls the latest virtual patches and generic web protection rules from the CrowdSec hub.
*   **Fail-Open WAF Operations**: In line with the stack's resilience goals, WAF checks are configured as fail-open by default (`crowdsecAppsecFailureBlock: false` and `crowdsecAppsecUnreachableBlock: false` inside `generate-config.py`). If the AppSec daemon experiences extreme load or crashes, traffic continues to route normally without generating false-positive service outages.
*   **Immediate Remediation Profiles**: While standard HTTP behavior anomalies (such as brute force or rapid scanning) trigger temporary CAPTCHA challenges to allow human recovery, AppSec WAF triggers bypass CAPTCHAs. In `config/crowdsec/profiles.yaml`, the captcha rule filters out AppSec triggers (`!(Alert.GetScenario() contains "appsec")`), sending WAF matches directly to the aggressive 24-hour IP ban remediation, as payload vulnerabilities represent high-confidence attack signatures.

---

## Operational Automation Scripts

The automation scripts in the `scripts/` directory handle stack lifecycle, configuration validation, and diagnostics:

*   **`start.sh`**: Handles stack startup. It runs validation checks on configuration files, generates dynamic settings for Traefik and Redis, verifies directory structures under `./data`, creates missing bridge networks, boots security services, and registers API keys in CrowdSec.
*   **`stop.sh`**: Shuts down the stack. It resolves the active Compose files, stops running containers, tears down the network bridges, and removes temporary runtime flags.
*   **`generate-config.py`**: Compiles routing rules. It reads `domains.csv`, checks for CAPTCHA credentials matching the root domains, groups subdomains into SAN certificate batches, and generates Traefik's dynamic routing files and Compose manifests.
*   **`health.sh`**: Runs diagnostics. It verifies that `.env` and `acme.json` permissions are restricted to `600`, queries container APIs, and confirms that database caches are responsive.
*   **`setup-grafana-alerting.sh`**: Provisions Grafana notifications. It runs inside the Grafana container, checks for active Telegram bot credentials, registers the contact point, and configures notification routing policies.
*   **`crowdsec-geoblock.sh`**: Handles geographic blocking. It downloads CIDR blocks for specified country codes from IPDeny and runs batch commands inside the CrowdSec container to block or unblock geographic zones.
*   **`maintenance.sh`**: Manages maintenance mode. It creates a flag file that updates the Compose manifests list, starting an Nginx container that serves the offline template for all public routes while keeping the admin dashboard accessible.
*   **`create-local-certs.sh`**: Automates local certificates. It checks for `mkcert` on the host, creates a local Root CA, and signs self-signed certificates for all domains listed in `domains.csv`.

### Config Generation Pipeline

The generation pipeline maps user configurations to the dynamic layers of the stack:

```mermaid
flowchart LR
    dist[domains.csv] --> generator[generate-config.py]
    env[.env] --> generator
    captchas[captcha_keys.csv] --> generator
    generator -->|Writes Compose Manifest| compose[docker-compose-anubis-generated.yaml]
    generator -->|Writes Traefik Routing Rules| routers[routers-generated.yaml]
    routers -->|Dynamic hot reload| Traefik[Traefik Router]
```

---

## Detailed Environment Variables Configuration

The environment configuration is split into system-managed variables and user-configured variables:

### System-Managed Variables

These keys must not be edited manually in the `.env` file, as the startup script regenerates or updates them to ensure system integrity:

*   `DASHBOARD_SECRET_KEY`: Used by the Flask dashboard to sign session cookies.
*   `CROWDSEC_WEB_UI_PASSWORD`: Internal database password for the CrowdSec console client.
*   `REDIS_PASSWORD`: Access password for the Valkey/Redis cache database.
*   `ANUBIS_REDIS_PRIVATE_KEY`: Private Ed25519 signing key for Anubis PoW cookies.
*   `CROWDSEC_API_KEY`: API bouncer key used by Traefik to query the CrowdSec LAPI.
*   `TRAEFIK_CERT_RESOLVER`: Set to `le` (Let's Encrypt) in production and staging, or left blank in local mode.

### User-Configured Variables

These variables control system behaviors and resource limits:

| Variable | Description | Recommended Value |
|:---|:---|:---|
| `DOMAIN` | Primary root domain name. | `company.com` |
| `TZ` | System timezone for logs and metrics. | `Europe/Madrid` |
| `PROJECT_NAME` | Namespace prefix for Compose containers. | `stack` |
| `ANUBIS_DIFFICULTY` | Cryptographic puzzle difficulty (1-5 scale). | `3` or `4` |
| `ANUBIS_CPU_LIMIT` | CPU core allocation limit per Anubis instance. | `0.10` |
| `ANUBIS_MEM_LIMIT` | Memory allocation limit per Anubis instance. | `32M` |
| `CROWDSEC_ENABLE` | Toggles the CrowdSec IPS firewall. | `true` |
| `CROWDSEC_APPSEC_ENABLE` | Toggles the Layer-7 WAF payload inspector. | `true` |
| `CROWDSEC_UPDATE_INTERVAL` | Ban list refresh interval in seconds. | `15` |
| `CROWDSEC_WHITELIST_IPS` | IPs/CIDRs that bypass all firewall blocks. | (comma-separated list) |
| `TRAEFIK_LISTEN_IP` | Bind address for ports 80 and 443. | `0.0.0.0` |
| `TRAEFIK_GLOBAL_RATE_AVG` | Default requests/second limit per client IP. | `60` |
| `TRAEFIK_GLOBAL_RATE_BURST` | Default request burst bucket capacity per client IP. | `120` |
| `TRAEFIK_GLOBAL_CONCURRENCY` | Default maximum concurrent sockets per client IP. | `25` |
| `TRAEFIK_TIMEOUT_ACTIVE` | HTTP request active read/write timeout in seconds. | `60` |
| `TRAEFIK_TIMEOUT_IDLE` | HTTP keep-alive connection timeout in seconds. | `90` |
| `TRAEFIK_BLOCKED_PATHS` | Path suffixes blocked immediately (403). | `/wp-admin/,/.env` |
| `TRAEFIK_BAD_USER_AGENTS` | User-Agents blocked immediately (403). | (comma-separated regex) |
| `TRAEFIK_GOOD_USER_AGENTS` | Trusted User-Agents that bypass stream bans. | (comma-separated regex) |
| `TRAEFIK_HSTS_MAX_AGE` | HSTS header lifetime in seconds. | `31536000` (1 year) |
| `TRAEFIK_ACME_ENV_TYPE` | Let's Encrypt environment (`production`/`staging`/`local`). | `production` |
| `WATCHDOG_TELEGRAM_BOT_TOKEN` | Telegram bot API token for health alerts. | (token from BotFather) |
| `WATCHDOG_TELEGRAM_RECIPIENT_ID` | Telegram chat/group ID for alerts. | (chat ID number) |
| `PROMETHEUS_RETENTION_DAYS` | Storage retention duration for metrics. | `15` |
| `PROMETHEUS_MEM_LIMIT` | Memory threshold limit for Prometheus. | `512M` |
| `DASHBOARD_SUBDOMAIN` | Subdomain for accessing the admin UI. | `dashboard` |

---

## Domain Routing Inventory Design

The `domains.csv` file manages public routing rules. Each line defines the routing and security settings for a domain name:

```csv
# domain, redirection, docker_service, anubis_subdomain, rate, burst, concurrency
```

*   **Column 1: `domain`**: The FQDN of the exposed application (e.g., `shop.company.com`).
*   **Column 2: `redirection`**: Optional target address. If populated, requests hitting the domain are redirected via HTTP 301 to this target (e.g., redirecting `www.shop.company.com` to `shop.company.com`).
*   **Column 3: `docker_service`**: The name of the Docker container exposing the service, which must run in the `traefik` network. If you want to route to a service running directly on the host, set this to the reserved keyword `apache-host`.
*   **Column 4: `anubis_subdomain`**: The subdomain used to serve the PoW challenge verification assets (e.g., setting `auth` inside `shop.company.com` serves challenges from `auth.shop.company.com`). Leave blank to disable anti-bot checks for this route.
*   **Column 5: `rate`**: Custom requests/second rate limit for this domain. If left blank, the stack uses the global average (`TRAEFIK_GLOBAL_RATE_AVG`).
*   **Column 6: `burst`**: Custom request burst bucket size. If left blank, the stack uses the global burst default (`TRAEFIK_GLOBAL_RATE_BURST`).
*   **Column 7: `concurrency`**: Custom concurrent socket limit. If left blank, the stack uses the global concurrency default (`TRAEFIK_GLOBAL_CONCURRENCY`).

---

## Makefile Administration Command Registry

The Makefile provides command wrappers to simplify stack administration:

### Stack Control

*   `make start`: Validates configuration files, compiles dynamic settings, verifies directory structures, and boots all services in sequence.
*   `make stop`: Gracefully stops the containers without removing persistent database folders in `./data/`.
*   `make restart`: Stops and boots up the stack from scratch.
*   `make restart [service]`: Restarts a single container service (e.g., `make restart traefik`).
*   `make rebuild`: Rebuilds custom Docker images (`dashboard` and `watchdog`) from their source Dockerfiles.
*   `make status`: Displays the status of running containers and health checks.
*   `make services`: Lists services defined within the active Compose files.
*   `make pull`: Pulls the latest external image updates from Docker Hub (Valkey, Prometheus, Loki, Grafana, etc.).

### Environment Management

*   `make init`: Runs the wizard setup script to initialize files and build Python virtual environment.
*   `make validate`: Compares `.env` variables against `.env.dist` and flags missing keys.
*   `make sync`: Merges any new master variables into `.env` without affecting custom keys.

### Security Operations

*   `make crowdsec-metrics`: Displays LAPI statistics (logs processed, active bouncers, scenarios).
*   `make crowdsec-decisions`: Lists active IP bans and durations.
*   `make crowdsec-alerts`: Lists the history of triggered alert scenarios.
*   `make crowdsec-ban [IP]`: Manually blocks an IP address for 4 hours.
*   `make crowdsec-unban [IP]`: Removes a banno or CAPTCHA restriction for an IP.
*   `make crowdsec-ban-country [ISO_CODE]`: Bans all IP ranges for selected country ISO codes (e.g., `make crowdsec-ban-country CN RU KP`).
*   `make crowdsec-unban-country [ISO_CODE]`: Removes bans for country ISO ranges.
*   `make crowdsec-appsec`: Outputs loaded rules and configurations inside the AppSec WAF plugin.

### Telemetry & Testing

*   `make health`: Performs connection checks on Traefik, CrowdSec LAPI, Redis, and Grafana APIs, and verifies secure `600` permissions on `.env` and `acme.json`.
*   `make logs`: Tails log output for all services.
*   `make logs [service]`: Tails log output for a specific container (e.g., `make logs watchdog`). Limit history using `tail=N` (e.g., `make logs traefik tail=50`).
*   `make shell [service]`: Spawns a shell terminal inside a running container (e.g., `make shell crowdsec`).
*   `make ctop`: Runs the interactive container hardware resource viewer.
*   `make grafana-setup-telegram`: Triggers manual configuration setup for Grafana Telegram alerts.
*   `make grafana-test-alert`: Sends a test alert payload to your Telegram channel to verify bot credentials.
*   `make redis-info` / `make redis-ping` / `make redis-monitor`: Utility commands to test Valkey database latency and streams.

### SSL Certs Control

*   `make certs-watch`: Tails Traefik logs filtering specifically for ACME validation events (requires `TRAEFIK_LOG_LEVEL=DEBUG`).
*   `make certs-info`: Prints a summary of domains in `domains.csv` with valid certificates inside `acme.json`.
*   `make certs-inspect`: Outputs detailed metadata for certificates (SANs, expiry dates).
*   `make certs-prune`: Runs a dry-run check for unused/orphaned certificates in `acme.json`.
*   `make certs-prune-force`: Removes orphan certificates from `acme.json`.

### Backup Management

*   `make backup`: Generates a timestamped tarball file inside `./backups/` capturing environment settings and certificates, excluding heavy databases.
*   `make restore file=[PATH]`: Overwrites current configs and restores settings from a backup tarball file.

### Maintenance & Reset

*   `make maintenance-on`: Intercepts all public traffic and serves the maintenance template.
*   `make maintenance-off`: Restores normal traffic routing.
*   `make clean`: Deletes generated dynamic configurations and backs up `acme.json` (requires manual confirmation).

---

## Special Operational Modes

### 1. Trusted Local Development Mode (mkcert)

To test domain routing on a local workstation using trusted self-signed certificates:

1.  Configure the environment variable type inside your `.env`:
    ```ini
    TRAEFIK_ACME_ENV_TYPE=local
    ```
2.  Launch the stack using `make start`.
3.  The startup script detects local mode and invokes `./scripts/create-local-certs.sh`. This script verifies if `mkcert` is installed, creates a local Root CA on the host, and signs certificates for all domains listed in `domains.csv`.
4.  The script then generates `local-certs.yaml` inside the dynamic configuration folder, instructing Traefik to load the signed local certificates and bypassing Let's Encrypt.

### 2. Legacy Host Application Integration

To route traffic to a web server (such as Apache or PHP-FPM) running directly on the host system while securing it through the edge proxy:

1.  Set the service column in `domains.csv` to `apache-host`.
2.  Set the host IP and the target listen port in `.env` (e.g., `APACHE_HOST_IP=172.17.0.1` and `APACHE_HOST_PORT=8080`).
3.  At startup, the script verifies connection connectivity to this port. If responsive, it appends the `docker-compose-apache-logs.yaml` manifest to the Compose configuration.
4.  This mounts the host's `/var/log/apache2` folder inside the log collector container, allowing CrowdSec to scan logs and apply security policies for the host service.

---

## FAQ and Operational Troubleshooting

### 1. Web browsers display untrusted certificate warnings

*   **Cause**: The environment type `TRAEFIK_ACME_ENV_TYPE` is set to `staging`. This uses Let's Encrypt's staging server, which issues untrusted certificates.
*   **Solution**: Change the value to `production` in `.env` and run `make start` to acquire production-valid certificates.

### 2. Protected domains fail to resolve or load

*   **Cause**: You have not set up a public DNS record pointing to the Anubis subdomain. If you set `auth` as the challenge subdomain for `shop.com`, you must create a Type A record pointing `auth.shop.com` to your public server IP.
*   **Solution**: Review the output of `make start` or check the Watchdog alert logs. The startup sequence validates FQDNs and prints warnings if DNS records are missing.

### 3. SSO login does not work on internal tools

*   **Cause**: The master SSO username or password in `.env` has been changed while the containers are running, causing credentials drift.
*   **Solution**: Stop the stack with `make stop`, run `make validate` to check configurations, and run `make start` to regenerate hashes and update settings.

### 4. Container files report directory permissions errors on startup

*   **Cause**: Services running as non-root users (Grafana UID 472, Prometheus UID 65534, Loki UID 10001) lack write permissions on folders mounted in `./data/`.
*   **Solution**: The startup script automatically attempts to correct this. If permissions errors persist, run the following commands on the host:
    ```bash
    sudo chown -R 472:472 ./data/grafana
    sudo chown -R 10001:10001 ./data/loki
    sudo chown -R 65534:65534 ./data/prometheus
    ```
    *(Note: If sudo is unavailable on the host, the start script falls back to `chmod 777` on these data volumes to ensure the services can write logs/metrics).*

---

## License

This project is licensed under the **MIT License**. For details, see the [LICENSE](LICENSE) file.
