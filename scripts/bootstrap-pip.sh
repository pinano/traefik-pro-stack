#!/usr/bin/env bash
# ============================================================================
# Bootstrap pip into the project virtualenv — audit M4 (2026-11-21).
#
# Old behaviour: curl -sS https://bootstrap.pypa.io/get-pip.py | python3
# → arbitrary code from the network executed with zero verification.
#
# New behaviour:
#   1. If pip is already available, do nothing.
#   2. Try `python -m ensurepip` (ships with the interpreter, no network).
#   3. Last resort: download get-pip.py to disk and verify it against the
#      PINNED_GET_PIP_SHA256 below before executing it.
#
# If the checksum fails, bootstrap.pypa.io has published a new get-pip.py.
# Refresh the pin deliberately:
#   curl -sS https://bootstrap.pypa.io/get-pip.py | sha256sum
# ============================================================================
set -euo pipefail

PYTHON_BIN="${1:-./.venv/bin/python3}"
GET_PIP_URL="https://bootstrap.pypa.io/get-pip.py"
PINNED_GET_PIP_SHA256="356e0d0de21cdc348c3394084d90939b85e4246c4d14c76aee6ca4f46646ea98"

# 1. pip already present → nothing to do.
if "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
    exit 0
fi

echo "📦 Bootstrapping pip..."

# 2. ensurepip — offline and signed with the interpreter.
if "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1; then
    echo "✅ pip installed via ensurepip."
    exit 0
fi

# 3. Verified download of get-pip.py.
if ! command -v curl >/dev/null 2>&1; then
    echo "❌ Error: neither ensurepip nor curl are available; cannot bootstrap pip." >&2
    exit 1
fi

TMP_GET_PIP=$(mktemp /tmp/get-pip.XXXXXX.py)
trap 'rm -f "$TMP_GET_PIP"' EXIT

curl -sS "$GET_PIP_URL" -o "$TMP_GET_PIP"
ACTUAL_SHA256=$(sha256sum "$TMP_GET_PIP" | awk '{print $1}')

if [ "$ACTUAL_SHA256" != "$PINNED_GET_PIP_SHA256" ]; then
    echo "❌ Error: get-pip.py checksum mismatch (expected $PINNED_GET_PIP_SHA256, got $ACTUAL_SHA256)." >&2
    echo "   Refusing to execute unverified code. If bootstrap.pypa.io published a" >&2
    echo "   new version, refresh PINNED_GET_PIP_SHA256 in scripts/bootstrap-pip.sh" >&2
    exit 1
fi

"$PYTHON_BIN" "$TMP_GET_PIP" -q
echo "✅ pip installed (checksum verified)."
