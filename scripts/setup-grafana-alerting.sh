#!/usr/bin/env bash
# scripts/setup-grafana-alerting.sh
# Configures Grafana Alerting (Telegram contact point + notification policy)
# via the Grafana Provisioning REST API.
#
# All API calls are made INSIDE the Grafana container via docker exec,
# so this works regardless of DNS resolution, TLS certificates, or
# whether Traefik is fully ready. No external URL needed.
#
# Called automatically from `make start` and can also be run manually:
#   make grafana-setup-telegram
#
# Exit codes:
#   0 — success or intentional skip (tokens not set, container not running)
#   1 — unexpected script error (set -e)
#
# Environment variables required (loaded from .env by Makefile):
#   PROJECT_NAME, DASHBOARD_ADMIN_USER, DASHBOARD_ADMIN_PASSWORD
#   WATCHDOG_TELEGRAM_BOT_TOKEN, WATCHDOG_TELEGRAM_RECIPIENT_ID

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
# Resolve container dynamically via Docker label or fallback to default pattern
DETECTED_GRAFANA=$(docker ps --quiet --filter "label=com.docker.compose.service=grafana" 2>/dev/null | head -n 1)
GRAFANA_CONTAINER="${DETECTED_GRAFANA:-${PROJECT_NAME:-stack}-grafana-1}"
AUTH="${DASHBOARD_ADMIN_USER:-admin}:${DASHBOARD_ADMIN_PASSWORD}"
CONTACT_POINT_NAME="Telegram"

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { :; }  # Silent by default to keep startup logs clean
success() { :; }
warn()    { echo "      ⚠️  $*"; }
skip()    { echo "      ✔ $*"; exit 0; }


# Run a curl command INSIDE the Grafana container (avoids DNS/TLS/Traefik issues)
grafana_api() {
    docker exec "${GRAFANA_CONTAINER}" \
        curl -sk -u "${AUTH}" "$@"
}

# ─── Guard: skip if Telegram is not configured ───────────────────────────────
if [[ -z "${WATCHDOG_TELEGRAM_BOT_TOKEN:-}" || "${WATCHDOG_TELEGRAM_BOT_TOKEN}" == "REPLACE_ME" ]]; then
    skip "WATCHDOG_TELEGRAM_BOT_TOKEN not configured — skipping Grafana alerting setup."
fi
if [[ -z "${WATCHDOG_TELEGRAM_RECIPIENT_ID:-}" || "${WATCHDOG_TELEGRAM_RECIPIENT_ID}" == "REPLACE_ME" ]]; then
    skip "WATCHDOG_TELEGRAM_RECIPIENT_ID not configured — skipping Grafana alerting setup."
fi

echo "   🔔 Grafana Alerting setup (Telegram)"

# ─── Guard: skip if Docker is not available ──────────────────────────────────
if ! command -v docker &>/dev/null; then
    skip "docker not found in PATH — skipping (run 'make grafana-setup-telegram' once Docker is available)."
fi

# ─── Wait for Grafana container to be running and healthy ─────────────────────
info "Waiting for Grafana container..."
GRAFANA_READY=false
for i in $(seq 1 24); do
    # Check container is running first (supports both container ID and container name)
    if ! docker inspect --format '{{.State.Running}}' "${GRAFANA_CONTAINER}" 2>/dev/null | grep -q "true"; then
        sleep 5
        continue
    fi
    # Then check Grafana's internal health endpoint
    if grafana_api "http://localhost:3000/api/health" 2>/dev/null | grep -q '"database": "ok"'; then
        GRAFANA_READY=true
        break
    fi
    sleep 5
done

if [[ "${GRAFANA_READY}" == "false" ]]; then
    warn "Grafana container '${GRAFANA_CONTAINER}' did not become healthy after 2 minutes."
    warn "Run 'make grafana-setup-telegram' manually once Grafana is up."
    exit 0  # Non-fatal: don't break 'make start'
fi
success "Grafana is up (container: ${GRAFANA_CONTAINER})."

# ─── Pre-flight: verify credentials have admin access ────────────────────────
info "Verifying admin credentials..."
AUTH_CHECK=$(grafana_api "http://localhost:3000/api/org" 2>/dev/null)
if echo "${AUTH_CHECK}" | grep -q '"id"'; then
    : # OK — /api/org returns the current org details for authenticated users
else
    warn "Admin credentials rejected by Grafana (HTTP 401/403)."
    warn "The DASHBOARD_ADMIN_PASSWORD in .env may not match the password stored in Grafana's database."
    warn ""
    warn "To fix, reset the Grafana admin password to match .env:"
    warn "  docker exec ${GRAFANA_CONTAINER} grafana cli admin reset-admin-password \"\${DASHBOARD_ADMIN_PASSWORD}\""
    warn ""
    warn "  (Note: This command resets the password for the main admin user (ID 1)"
    warn "   even if you have changed their username to something other than 'admin')"
    warn ""
    warn "Then run: make grafana-setup-telegram"
    exit 0  # Non-fatal
fi
success "Admin credentials OK."

# ─── Check if Telegram contact point already exists ──────────────────────────
info "Checking existing contact points..."
EXISTING=$(grafana_api "http://localhost:3000/api/v1/provisioning/contact-points")

if echo "${EXISTING}" | grep -q "\"name\":\"${CONTACT_POINT_NAME}\""; then
    info "Contact point '${CONTACT_POINT_NAME}' already exists — skipping creation."
    CONTACT_POINT_EXISTS=true
else
    CONTACT_POINT_EXISTS=false
fi

# ─── Custom Telegram message template (Go text/template + HTML) ──────────────
# We use jq --arg to pass the template as a safe JSON string, avoiding the
# shell quoting hell caused by Go's {{ if eq .Status "firing" }} syntax.
read -r -d '' TELEGRAM_TEMPLATE << 'GOTEMPLATE' || true
{{ if eq .Status "firing" }}{{ if eq (index .Alerts 0).Labels.severity "warning" }}🟠 <b>GRAFANA - Warning: {{ (index .Alerts 0).Labels.alertname }}</b>{{ else }}🔴 <b>GRAFANA - Critical: {{ (index .Alerts 0).Labels.alertname }}</b>{{ end }}{{ else }}🟢 <b>GRAFANA - Resolved: {{ (index .Alerts 0).Labels.alertname }}</b>{{ end }}
🌐 <b>{{ (index .Alerts 0).Labels.host }}</b>

{{ range .Alerts }}• <b>{{ .Labels.alertname }}</b>: <i>{{ .Annotations.description }}</i>
🚦 <b>Severity:</b> {{ .Labels.severity }}
{{ if .GeneratorURL }}🔗 <a href="{{ .GeneratorURL }}">View Alert</a>{{ end }}{{ if .SilenceURL }}  ·  🔕 <a href="{{ .SilenceURL }}">Silence</a>{{ end }}
{{ end }}
GOTEMPLATE

# Build the JSON payload safely with python3, passing all values as environment
# variables (never embedded in code). Using <<'PYEOF' (quoted delimiter) prevents
# bash from expanding ${{ }} in the Go template or any token in the bot token.
PAYLOAD=$(TELEGRAM_BOT_TOKEN="${WATCHDOG_TELEGRAM_BOT_TOKEN}" \
          TELEGRAM_CHAT_ID="${WATCHDOG_TELEGRAM_RECIPIENT_ID}" \
          TELEGRAM_TEMPLATE="${TELEGRAM_TEMPLATE}" \
          TELEGRAM_CONTACT_NAME="${CONTACT_POINT_NAME}" \
          python3 - <<'PYEOF'
import json, os

payload = {
    "name":    os.environ["TELEGRAM_CONTACT_NAME"],
    "type":    "telegram",
    "settings": {
        "chatid":                   os.environ["TELEGRAM_CHAT_ID"],
        "bottoken":                 os.environ["TELEGRAM_BOT_TOKEN"],
        "parse_mode":               "HTML",
        "disable_web_page_preview": True,
        "message":                  os.environ["TELEGRAM_TEMPLATE"],
    },
    "disableResolveMessage": False,
}
print(json.dumps(payload))
PYEOF
)

# ─── Create contact point (only if it doesn't exist) ─────────────────────────
if [[ "${CONTACT_POINT_EXISTS}" == "false" ]]; then
    info "Creating '${CONTACT_POINT_NAME}' contact point..."

    RESPONSE=$(grafana_api -X POST \
        -H "Content-Type: application/json" \
        "http://localhost:3000/api/v1/provisioning/contact-points" \
        --data-raw "${PAYLOAD}")

    if echo "${RESPONSE}" | grep -q '"uid"'; then
        success "Contact point created."
    else
        warn "Unexpected response: ${RESPONSE}"
    fi
else
    # Contact point exists — patch it to apply the latest message template.
    EXISTING_UID=$(python3 -c "import sys, json; data = json.loads(sys.stdin.read()); print(next((cp['uid'] for cp in data if cp['name'] == '${CONTACT_POINT_NAME}'), ''))" <<< "${EXISTING}" 2>/dev/null || true)

    if [[ -n "${EXISTING_UID}" ]]; then
        info "Updating message template on existing '${CONTACT_POINT_NAME}' (uid: ${EXISTING_UID})..."
        RESPONSE=$(grafana_api -X PUT \
            -H "Content-Type: application/json" \
            "http://localhost:3000/api/v1/provisioning/contact-points/${EXISTING_UID}" \
            --data-raw "${PAYLOAD}")

        if echo "${RESPONSE}" | grep -qE '"uid"|"message"|^$'; then
            success "Contact point updated."
        else
            warn "Unexpected response while updating: ${RESPONSE}"
        fi
    else
        warn "Could not extract UID for '${CONTACT_POINT_NAME}' — skipping message template update."
    fi
fi

# ─── Set notification policy (only if not already routing to Telegram) ────────
info "Checking notification policy..."
CURRENT_POLICY=$(grafana_api "http://localhost:3000/api/v1/provisioning/policies")
CURRENT_RECEIVER=$(python3 -c "import sys, json; data = json.loads(sys.stdin.read()); print(data.get('receiver', ''))" <<< "${CURRENT_POLICY}" 2>/dev/null || true)

if [[ "${CURRENT_RECEIVER}" == "${CONTACT_POINT_NAME}" ]]; then
    info "Notification policy already routes to '${CONTACT_POINT_NAME}' — skipping."
else
    info "Setting notification policy → '${CONTACT_POINT_NAME}'..."
    RESPONSE=$(grafana_api -X PUT \
        -H "Content-Type: application/json" \
        "http://localhost:3000/api/v1/provisioning/policies" \
        --data-raw "{
            \"receiver\": \"${CONTACT_POINT_NAME}\",
            \"group_by\": [\"alertname\", \"severity\"],
            \"group_wait\": \"30s\",
            \"group_interval\": \"5m\",
            \"repeat_interval\": \"4h\",
            \"routes\": [
                {
                    \"receiver\": \"${CONTACT_POINT_NAME}\",
                    \"matchers\": [\"severity = critical\"],
                    \"group_wait\": \"10s\",
                    \"group_interval\": \"2m\",
                    \"repeat_interval\": \"1h\"
                },
                {
                    \"receiver\": \"${CONTACT_POINT_NAME}\",
                    \"matchers\": [\"severity = warning\"],
                    \"group_wait\": \"30s\",
                    \"group_interval\": \"5m\",
                    \"repeat_interval\": \"4h\"
                }
            ]
        }")

    if echo "${RESPONSE}" | grep -qE '"policies updated"|"receiver"'; then
        success "Notification policy set."
    else
        warn "Unexpected response: ${RESPONSE}"
    fi
fi

echo "      ✔ Grafana Alerting ready. Run 'make grafana-test-alert' to verify."
