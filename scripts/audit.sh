#!/bin/bash
# =============================================================================
# SECURITY & PERFORMANCE AUDIT (read-only)
# Usage: make audit          (or ./scripts/audit.sh)
# Exit codes: 0 = no FAIL findings, 1 = at least one FAIL.
# WARN findings require manual review (see docs/SECURITY-AUDIT-CHECKLIST.md).
# This script never modifies the system: safe to run in production.
# =============================================================================
set -u

RED=31; YELLOW=33; GREEN=32
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "🟢 [\033[1;${GREEN}mPASS\033[0m] $1"; PASS=$((PASS+1)); }
warn() { echo -e "🟡 [\033[1;${YELLOW}mWARN\033[0m] $1"; WARN=$((WARN+1)); }
bad()  { echo -e "🔴 [\033[1;${RED}mFAIL\033[0m] $1"; FAIL=$((FAIL+1)); }
info() { echo -e "🔵 [INFO] $1"; }

section() { echo ""; echo "═══════════════ $1 ═══════════════"; }

# Load .env without executing it (safer than source: only KEY=VALUE lines)
if [ -f .env ]; then
    while IFS='=' read -r key val; do
        case "$key" in ''|\#*|'export ') ;; # skip comments/blank
        *) export "$key=${val%\"}";;
        esac
    done < <(grep -v '^$' .env)
fi

# -----------------------------------------------------------------------------
section "1. FILE PERMISSIONS & SECRETS HYGIENE"
# -----------------------------------------------------------------------------
check_perms() {
    local file=$1 expected=$2 critical=${3:-true}
    if [ -f "$file" ]; then
        local perms
        perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%A' "$file" 2>/dev/null)
        if [ "$perms" -le "$expected" ] 2>/dev/null; then
            ok "$file: $perms (≤ $expected)"
        elif [ "$critical" = "true" ]; then
            bad "$file: $perms (expected ≤ $expected) — contains secrets, run: chmod $expected '$file'"
        else
            warn "$file: $perms (recommended ≤ $expected)"
        fi
    else
        info "$file not found (skipped)"
    fi
}

check_perms ".env" 600
check_perms "config/traefik/acme.json" 600
check_perms "config/crowdsec/captcha_keys.csv" 600
# Generated files that embed secrets (Redis password, LAPI key, DB password)
check_perms "config/valkey/valkey-generated.conf" 600 false
check_perms "config/crowdsec/config.yaml.local" 600 false
check_perms "config/traefik/dynamic-config/routers-generated.yaml" 644 false
# Databases with session data / password hashes
check_perms "config/crowdsec-web-ui/crowdsec.db" 600 false
check_perms "data/filebrowser/filebrowser.db" 600 false

# Scripts bind-mounted into the watchdog container and exec'd by its cron:
# a lost exec bit silently disables SSL/DNS/CrowdSec monitoring.
WATCHDOG_NOT_EXEC=""
for f in config/watchdog/*.sh; do
    [ -x "$f" ] || WATCHDOG_NOT_EXEC="$WATCHDOG_NOT_EXEC $f"
done
if [ -n "$WATCHDOG_NOT_EXEC" ]; then
    bad "watchdog scripts missing exec bit:$WATCHDOG_NOT_EXEC — their checks silently never run. Fix: chmod +x$WATCHDOG_NOT_EXEC"
else
    ok "watchdog scripts executable"
fi

if grep -qE '^(REDIS_PASSWORD|CROWDSEC_LAPI_KEY|DASHBOARD_SECRET_KEY)=.{8,}' config/traefik/dynamic-config/routers-generated.yaml 2>/dev/null; then
    warn "routers-generated.yaml embeds live secrets (LAPI/Redis). Acceptable at 644 only on single-admin hosts; Traefik reads it as root."
fi

# -----------------------------------------------------------------------------
section "2. ENVIRONMENT CONFIGURATION"
# -----------------------------------------------------------------------------
if [ "${DASHBOARD_ADMIN_PASSWORD:-}" = "password" ]; then
    bad "Dashboard admin uses default credentials (admin/password). Change before production."
fi
if grep -q "REPLACE_ME" .env 2>/dev/null; then
    warn "Watchdog Telegram token/chat-id still contain REPLACE_ME (alerts silently dropped)."
fi
case "${TRAEFIK_ACME_ENV_TYPE:-}" in
    production) ok "ACME environment: production" ;;
    local)      info "ACME environment: local (dev mode)" ;;
    staging)    if [[ "${DOMAIN:-}" == *.localhost ]]; then info "ACME staging + .localhost domain (dev)"; else warn "ACME staging with real domain ${DOMAIN:-?} — browsers will show cert warnings."; fi ;;
    *)          warn "TRAEFIK_ACME_ENV_TYPE not set" ;;
esac
if [ "${TRAEFIK_HSTS_MAX_AGE:-0}" -ge 31536000 ] 2>/dev/null; then
    warn "HSTS is 1 year with preload. Ensure EVERY domain/subdomain in domains.csv is permanently HTTPS-only before this is used in production."
fi
if [ -z "${TRAEFIK_TRUSTED_IPS:-}" ] && [ "${TRAEFIK_ACME_ENV_TYPE:-}" = "production" ]; then
    warn "TRAEFIK_TRUSTED_IPS empty in production: if this host sits behind a CDN/proxy, CrowdSec sees the CDN's IP, not the client's."
fi
# A5: Anubis per-instance memory ceiling (limits are ceilings, not reservations)
case "${ANUBIS_MEM_LIMIT^^}" in
    32M|64M|96M|128M) warn "ANUBIS_MEM_LIMIT=${ANUBIS_MEM_LIMIT} per instance is too low: Anubis OOMs under a PoW flood and traffic fails open. Recommended ≥ 256M." ;;
    "")               info "ANUBIS_MEM_LIMIT unset — compose default (256M) applies" ;;
    *)                ok "Anubis memory limit: ${ANUBIS_MEM_LIMIT} per instance" ;;
esac
# M6: crowdsec-web-ui must authenticate on its own (defense in depth)
if grep -q "AUTH_ENABLED=true" docker-compose-security.yaml 2>/dev/null; then
    ok "crowdsec-web-ui has its own auth enabled"
else
    warn "crowdsec-web-ui runs with AUTH_ENABLED=false — the UI relies solely on edge middleware (audit M6)."
fi
# M7: Prometheus must enforce remote-write auth server-side
if [ -f config/prometheus/web-generated.yml ] && grep -q '\$2[aby]\$' config/prometheus/web-generated.yml 2>/dev/null; then
    ok "Prometheus remote-write auth enforced server-side (bcrypt web config present)"
else
    warn "config/prometheus/web-generated.yml missing or without bcrypt hash — any container on the 'traefik' network can poison metrics (audit M7). Run 'make start'."
fi

# -----------------------------------------------------------------------------
section "3. TRAEFIK EDGE POLICY"
# -----------------------------------------------------------------------------
if grep -qi "crowdsec-bouncer-traefik-plugin" config/traefik/traefik.yaml.template; then
    ok "CrowdSec bouncer plugin declared in static config"
else
    bad "CrowdSec bouncer plugin missing from traefik.yaml.template"
fi
if grep -q "minVersion: VersionTLS12" config/traefik/traefik.yaml.template; then
    ok "TLS minimum version 1.2 enforced"
fi
# Informational: Anubis PoW is intentionally not enforced on static-asset
# URLs (cookie-based flow). CrowdSec bans ARE enforced there since 2026-11-21.
if grep -q "static-assets-" config/traefik/dynamic-config/routers-generated.yaml 2>/dev/null; then
    info "REMINDER: static-assets routers enforce CrowdSec bans (crowdsec-check-assets, no AppSec). Anubis PoW is intentionally not applied to asset URLs; /static/* and /assets/* path ALLOWs in botPolicy.yaml remain a documented, rate-limited exception."
fi
# Anubis good-bots UA trust (multi-line YAML check: action on the line after user_agent_regex)
if grep -A1 "user_agent_regex" config/anubis/botPolicy.yaml 2>/dev/null | grep -qE "action:\s*ALLOW"; then
    warn "Anubis policy has an ALLOW rule tied to user_agent_regex — trivially spoofable PoW bypass. See botPolicy.yaml security comment."
fi

# -----------------------------------------------------------------------------
section "4. DOCKER HARDENING (requires running daemon)"
# -----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    latest=$(docker ps --format '{{.Image}}' | grep -E ':(latest)$|^[a-z0-9_/.-]+$' | head -5)
    if [ -n "$latest" ]; then warn "Containers using floating/:latest tags:\n$latest"; else ok "No floating image tags"; fi

    nolimit=$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.Memory}}' | awk '$2==0{print $1}' | head -10)
    if [ -n "$nolimit" ]; then warn "Containers without memory limit: $nolimit"; else ok "All running containers have memory limits"; fi

    post=$(docker inspect docker-socket-proxy --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^POST=' | head -1)
    if [ "$post" = "POST=0" ] || [ -z "$post" ]; then ok "Global docker-socket-proxy is read-only"; else bad "docker-socket-proxy has POST enabled"; fi
else
    info "Docker daemon not reachable — docker hardening checks skipped"
fi

# -----------------------------------------------------------------------------
section "5. CROWDSEC STATE (requires running daemon)"
# -----------------------------------------------------------------------------
# Match the CrowdSec container regardless of compose project naming
# (stack-crowdsec-1, traefik-crowdsec-1, ...), excluding its db/web-ui.
cs_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep 'crowdsec' | grep -Ev 'db|web-ui|exporter' | head -1)
if [ -n "$cs_container" ]; then
    decisions=$(docker exec "$cs_container" cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)
    info "Active CrowdSec decisions: $decisions"
    wl=$(docker exec "$cs_container" cscli parser list -o raw 2>/dev/null | grep -ci whitelist || true)
    info "Custom whitelist parsers loaded: $wl (verify they only contain private ranges + your admin IPs)"
else
    info "CrowdSec container not running — state checks skipped"
fi

# -----------------------------------------------------------------------------
section "6. PERFORMANCE SANITY"
# -----------------------------------------------------------------------------
ret="${PROMETHEUS_RETENTION_DAYS:-15}"; mem="${PROMETHEUS_MEM_LIMIT:-1G}"
if [ "$ret" -gt 30 ] 2>/dev/null && [ "$mem" = "1G" ]; then
    warn "PROMETHEUS_RETENTION_DAYS=$ret with ${mem} memory limit risks OOM. Rule of thumb: ~1.5GB per 15 days."
else
    ok "Prometheus retention (${ret}d / ${mem}) looks balanced"
fi
vm=$(grep -E '^maxmemory' config/valkey/valkey.conf 2>/dev/null | head -1)
vm_mb=$(echo "$vm" | grep -oE '[0-9]+' | head -1)
if [ -n "$vm_mb" ] && [ "$vm_mb" -le 410 ] 2>/dev/null; then
    ok "Valkey ${vm} leaves headroom under the 512M cgroup ceiling (kernel OOM avoided)"
else
    warn "Valkey ${vm:-no maxmemory set} is too close to the 512M cgroup limit — the kernel will OOM-kill instead of evicting (audit M8 recommends ≤ 400mb)."
fi
if [ "${TRAEFIK_LOG_LEVEL:-INFO}" = "DEBUG" ]; then warn "TRAEFIK_LOG_LEVEL=DEBUG in production hurts latency and fills disks."; fi
info "Access log buffer: ${TRAEFIK_ACCESS_LOG_BUFFER:-1000} lines (1000 recommended for production)"

# -----------------------------------------------------------------------------
echo ""
echo "═══════════════ AUDIT SUMMARY ═══════════════"
echo -e "🟢 PASS: $PASS   🟡 WARN: $WARN   🔴 FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
