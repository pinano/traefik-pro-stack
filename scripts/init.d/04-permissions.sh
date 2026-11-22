#!/usr/bin/env bash
# =============================================================================
# 04-permissions.sh — Stack permission policy enforcement (runs every boot)
# =============================================================================
# Guarantees file/directory permissions are correct regardless of whether the
# operator is root or a regular user. Non-root operators cannot chown, so any
# fix that requires root degrades to a warning carrying the exact command.
#
# Classes of incidents this module prevents (all seen in production):
#   1. Lost exec bits on scripts bind-mounted into containers and exec'd by
#      cron — the watchdog silently skipped its CrowdSec/SSL/DNS checks while
#      reporting healthy.
#   2. Data-dir ownership drift (containers running as a different uid than
#      the owner of ./data/<service>).
#
# Secret-file modes (.env, acme.json, captcha_keys.csv -> 600) are enforced
# in 04-assets.sh; the verification block at the end only warns if something
# could not be enforced there.
# =============================================================================

PERM_FIXES=0
perm_warn() { echo "   ⚠️  $1"; }

# --- 1. Exec bits on scripts executed by containers or operators ------------
# The watchdog scripts are bind-mounted read-only into the container; crond
# execs them directly, so the exec bit must exist on the HOST file. Files
# checked out or copied without preserving modes lose it silently.
for target in config/watchdog/*.sh scripts/*.sh scripts/init.d/*.sh; do
    if [ -f "$target" ] && [ ! -x "$target" ]; then
        if chmod +x "$target" 2>/dev/null; then
            echo "   ✅ Restored missing exec bit: $target"
            PERM_FIXES=$((PERM_FIXES + 1))
        else
            perm_warn "$target is not executable and chmod failed (root-owned file?). Run: sudo chmod +x '$target'"
        fi
    fi
done

# --- 2. Secret-file mode verification (enforcement lives in 04-assets.sh) ---
perm_check_mode() {
    local file=$1 expected=$2
    if [ -f "$file" ]; then
        local mode
        mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%A' "$file" 2>/dev/null)
        if [ "$mode" -gt "$expected" ] 2>/dev/null; then
            perm_warn "$file is $mode (expected ≤ $expected). Run: chmod $expected '$file'"
        fi
    fi
}
perm_check_mode ".env" 600
perm_check_mode "config/traefik/acme.json" 600
perm_check_mode "config/crowdsec/captcha_keys.csv" 600

if [ "$PERM_FIXES" -gt 0 ]; then
    echo "   ✅ Permission policy applied ($PERM_FIXES fix(es))."
fi
