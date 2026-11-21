#!/bin/bash
# set-anubis-limits.sh — set Anubis resource limits in .env and apply them.
#
# Usage (from the repo root on any host):
#   ./scripts/set-anubis-limits.sh              # 256M / 0.5 CPU (audit defaults)
#   ./scripts/set-anubis-limits.sh 512M 1.0     # custom values
#
# Edits ANUBIS_MEM_LIMIT / ANUBIS_CPU_LIMIT in place (never rebuilds .env),
# then runs `make start` so compose recreates only the Anubis containers.
set -euo pipefail

MEM="${1:-256M}"
CPU="${2:-0.5}"

if ! [[ "$MEM" =~ ^[0-9]+[MG]$ ]]; then
    echo "❌ MEM must look like 256M or 1G (got: '$MEM')"
    exit 1
fi
if ! [[ "$CPU" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v c="$CPU" 'BEGIN{exit !(c>0)}'; then
    echo "❌ CPU must be a positive number (got: '$CPU')"
    exit 1
fi

# Always operate on the repo root, regardless of the caller's cwd.
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "❌ .env not found in $(pwd)"; exit 1; }

echo "Previous values:"
grep -E "^ANUBIS_(MEM_LIMIT|CPU_LIMIT)=" .env || echo "  (not set — falling back to compose defaults)"

# In-place edit only — .env holds every secret in the stack and is never
# rebuilt from scratch here (values are digits/dots, safe for sed).
for kv in "ANUBIS_MEM_LIMIT=$MEM" "ANUBIS_CPU_LIMIT=$CPU"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    if grep -q "^$key=" .env; then
        sed -i "s/^$key=.*/$key=$val/" .env
    else
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
done
chmod 600 .env

echo "New values:"
grep -E "^ANUBIS_(MEM_LIMIT|CPU_LIMIT)=" .env

echo "▶ Applying (make start — recreates only the Anubis containers)..."
make start
