#!/bin/sh

# =============================================================================
# Watchdog Entrypoint
# =============================================================================
# Translates second-based intervals into cron (minute) expressions and
# generates the root crontab, then launches crond in the foreground.

echo "🔄 Initializing Watchdog Cron configuration..."

# Helper function to convert seconds to minutes safely (min 1 minute)
sec_to_min() {
    local seconds=$1
    local minutes=$(( seconds / 60 ))
    if [ "$minutes" -lt 1 ]; then
        minutes=1
    fi
    echo "$minutes"
}

sys_min=$(sec_to_min "${WATCHDOG_SYSTEM_CHECK_INTERVAL:-300}")
traefik_min=$(sec_to_min "${WATCHDOG_TRAEFIK_CHECK_INTERVAL:-300}")
dns_min=$(sec_to_min "${WATCHDOG_DNS_CHECK_INTERVAL:-21600}")

# Start crontab generation
CRONTAB_FILE="/etc/crontabs/root"
echo "# Watchdog Auto-Generated Crontab" > "$CRONTAB_FILE"

# 1. System checks
echo "*/${sys_min} * * * * /check-system.sh" >> "$CRONTAB_FILE"

# 2. Traefik checks
echo "*/${traefik_min} * * * * /check-traefik.sh" >> "$CRONTAB_FILE"

# 3. DNS checks
# For DNS, if the interval is >= 60 minutes (e.g., 21600s = 360m), cron */M format 
# requires M <= 59. So we convert large intervals to hours if perfectly divisible, 
# otherwise we default to a safe value. 21600s is exactly 6 hours.
dns_hours=$(( dns_min / 60 ))
if [ "$dns_hours" -ge 1 ] && [ $(( dns_min % 60 )) -eq 0 ]; then
    echo "0 */${dns_hours} * * * /check-dns.sh" >> "$CRONTAB_FILE"
else
    # Fallback to every 59 minutes if math is weird to avoid cron syntax errors
    if [ "$dns_min" -gt 59 ]; then
        dns_min=59
    fi
    echo "*/${dns_min} * * * * /check-dns.sh" >> "$CRONTAB_FILE"
fi

# 4. Certificates check (Daily at midnight)
echo "0 0 * * * /check-certs.sh" >> "$CRONTAB_FILE"

# 5. CrowdSec checks (Conditional)
if [ "${CROWDSEC_ENABLE:-true}" != "false" ]; then
    cs_min=$(sec_to_min "${WATCHDOG_CROWDSEC_CHECK_INTERVAL:-3600}")
    cs_hours=$(( cs_min / 60 ))
    if [ "$cs_hours" -ge 1 ] && [ $(( cs_min % 60 )) -eq 0 ]; then
        echo "0 */${cs_hours} * * * /check-crowdsec.sh" >> "$CRONTAB_FILE"
    else
        if [ "$cs_min" -gt 59 ]; then
            cs_min=59
        fi
        echo "*/${cs_min} * * * * /check-crowdsec.sh" >> "$CRONTAB_FILE"
    fi
else
    echo "⚠️ CrowdSec check is DISABLED."
fi

echo "✅ Crontab generated successfully:"
cat "$CRONTAB_FILE"
echo ""
echo "🚀 Starting Cron Daemon (crond)..."

# Run crond in foreground with log level 2 (logs to stderr)
exec crond -f -l 2
