# Security & Performance Audit Checklist

Standard methodology to audit this stack periodically (recommended: **quarterly** in production, and **always** before tagging a release or after adding new domains).

> Quick run: `make audit` (automatic checks) + manual review of sections 4-7 of this document.
> The latest dated report lives in `docs/audits/`.

---

## 1. Automatic checks (`make audit`)

Covers: secret file permissions, default credentials, unconfigured tokens, ACME mode, floating images, container memory limits, socket-proxy policy and performance sanity (Prometheus retention/memory, Valkey maxmemory, log level).

**Never modifies the system. Exits 1 if there is any FAIL.**

## 2. Permissions and secrets (manual: `stat`, `grep`)

| File | Expected |
|---|---|
| `.env` | 600 |
| `config/traefik/acme.json` | 600 |
| `config/crowdsec/captcha_keys.csv` | 600 |
| `config/valkey/valkey-generated.conf` | ≤ 600 (contains `REDIS_PASSWORD`) |
| `config/crowdsec/config.yaml.local` | ≤ 600 (contains `CROWDSEC_DB_PASSWORD`) |
| `config/traefik/dynamic-config/routers-generated.yaml` | 644 (contains LAPI key + Redis password — acceptable only on a single-admin host) |
| `data/filebrowser/filebrowser.db`, `config/crowdsec-web-ui/crowdsec.db` | ≤ 600 (hashes/sessions) |

Also verify: that no new `echo` in `scripts/init.d/` prints secret values; that `generate-config.py` does not write configs again without atomic write.

## 3. Environment configuration

- `DASHBOARD_ADMIN_PASSWORD` ≠ `password`/`admin` (the panel can restart containers).
- `TRAEFIK_ACME_ENV_TYPE=production` only with verified domains; `staging` when testing.
- `WATCHDOG_TELEGRAM_BOT_TOKEN` set (otherwise the alerts do not exist).
- If there is a CDN/proxy in front: `TRAEFIK_TRUSTED_IPS` with the provider's real IPs (never private ranges — see §6).
- `TRAEFIK_HSTS_MAX_AGE` with preload: confirm that **all** subdomains are permanently HTTPS.

## 4. Edge chain (Traefik)

1. Middleware order (in `generate-config.py`): redirect → UA-block → CrowdSec → buffering → headers → rate limit → concurrency → retry → Anubis → compress.
2. **State of the known bypasses (review on every audit):**
   - Router `static-assets-*` (priority 500): **fixed A2 (2026-11-21)** — now applies `crowdsec-check-assets` (bans yes, AppSec no) and rate limit 100/200. Anubis PoW is still not applied to assets by design (cookie-based flow). Verify in `routers-generated.yaml` that the chain includes `crowdsec-check-assets`.
   - ~~`botPolicy.yaml` → `good-bots` allows `Googlebot|Bingbot...` by User-Agent~~ — **removed (fixed A1, 2026-11-21)**. Guarded by `test_anubis_policy_no_spoofable_ua_allow`. Do not reintroduce `user_agent_regex` ALLOWs.
   - `botPolicy.yaml` → `/static/*` and `/assets/*` ALLOW without challenge: deliberate exception, covered by CrowdSec + rate limit on the assets router.
3. `minVersion: VersionTLS12` present; bouncer plugin with pinned version.

## 5. Docker hardening

- `docker ps --format '{{.Image}}'` — no `:latest`.
- Containers with memory limits (`docker inspect`).
- Global socket-proxy read-only (`POST=0`); the dashboard one with `POST/DELETE/EXEC` (known surface: equivalent to root if the dashboard is compromised — keep the panel updated and with a strong password).
- `no-new-privileges=true` on all services.
- LAPI on `127.0.0.1:8090` only; AppSec and metrics without public `ports:`.

## 6. Critical invariants (do not break)

1. **Global private-IP whitelist** in CrowdSec (`05-local-certs-and-network.sh`) is only safe because Traefik **does not trust** X-Forwarded-For from external clients. If `forwardedHeaders.trustedIPs` is ever enabled with a CDN, review the whitelist (an attacker could spoof `X-Forwarded-For: 10.x.x.x` and become invisible).
2. **Fail-open by design**: if CrowdSec/Redis/Anubis go down, traffic passes. That is why the Anubis/Valkey/CrowdSec memory limits must have headroom (taking down the firewall = disabling it). `ANUBIS_MEM_LIMIT` ≥ 256M recommended in production.
3. `crowdsec-web-ui` has its own login (`AUTH_ENABLED=true`, fixes M6). Do not reintroduce `AUTH_ENABLED=false` even though Traefik puts the edge chain in front of it.
4. **Prometheus enforces server-side Basic auth** (`--web.config.file`, fixes M7): the bcrypt hash is regenerated on every `make start` from `PROMETHEUS_REMOTE_WRITE_TOKEN`. The self-scrape uses `password_file` and the healthcheck sends credentials in the URL — if you change the mechanism, keep the three in sync.
5. **Add-first bouncer key rotation** (fixes M1): only rotates if the SHA-256 fingerprint in `.bouncer_key.fingerprint` changes. Deleting and re-adding on every boot opens a no-bouncer window (fail-open).
6. **Generated 600 configs are read by containers running as the operator uid** (`HOST_UID`/`HOST_GID`, auto-synced on every boot — valkey, prometheus). If a container crashes with `permission denied` on a generated file, compare `id -u` with `HOST_UID` in `.env` and run `make start` again.

## 7. Performance

| Tuning | Rule |
|---|---|
| Valkey | `maxmemory` ≈ 80% of the container limit (400mb vs 512M — LRU eviction kicks in before the kernel kills the process) |
| Prometheus | ~1.5 GB of limit per 15 days of retention |
| CrowdSec PostgreSQL | `max_connections=50`, `work_mem=8MB` under prolonged attack |
| Loki | `ingestion_rate_mb` 15 may drop logs mid-DDoS (429); Docker `json-file` logs are the forensic fallback |
| Traefik | `TRAEFIK_LOG_LEVEL=INFO` in production; access log buffer 1000 |

## 8. Audit pipeline (for the assistant)

1. `make audit` → collect FAIL/WARN.
2. `make test` (unit) + `make health` if the stack is up.
3. Manual review of §2-§7 (this document).
4. Diff the latest dated report (`docs/audits/`) against the current state: regressions and closed findings.
5. Issue `docs/audits/YYYY-MM-DD-security-audit.md` with severities (critical/high/medium/low/informational) and a prioritized remediation plan.
6. Do not tag a new release until critical/high findings are closed.
