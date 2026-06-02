#!/usr/bin/env bash
# =============================================================================
# crowdsec-geoblock.sh — Ban or unban all IP ranges for one or more countries via CrowdSec
#
# Usage:
#   ./scripts/crowdsec-geoblock.sh ban   CN RU KP        # Ban China, Russia, North Korea
#   ./scripts/crowdsec-geoblock.sh unban CN              # Unban China
#
# Country codes must be ISO 3166-1 alpha-2 (two letters, case-insensitive).
# IP ranges sourced from https://www.ipdeny.com/ipblocks/data/aggregated/
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# Global cleanup on exit/error
cleanup() {
    rm -f /tmp/geoblock_ban_* /tmp/geoblock_unban_* /tmp/geoblock_ranges_*
}
trap cleanup EXIT INT TERM


# progress_bar CURRENT TOTAL LABEL
# Prints an in-place progress bar to stderr. Call with CURRENT==TOTAL for the
# final "done" line (which adds a newline so subsequent output is clean).
progress_bar() {
    local current=$1 total=$2 label="$3"
    local width=40
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar
    bar="$(printf '%0.s█' $(seq 1 $filled 2>/dev/null))$(printf '%0.s░' $(seq 1 $empty 2>/dev/null))"
    local pct=$(( current * 100 / total ))
    if [[ $current -ge $total ]]; then
        printf "\r  ${GREEN}${bar}${RESET} %3d%%  %d/%d %s\n" "$pct" "$current" "$total" "$label" >&2
    else
        printf "\r  ${CYAN}${bar}${RESET} %3d%%  %d/%d %s" "$pct" "$current" "$total" "$label" >&2
    fi
}

# -----------------------------------------------------------------------------
# Validate arguments
# -----------------------------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: $0 {ban|unban} COUNTRY [COUNTRY ...]"
    echo "       $0 ban   CN RU KP"
    echo "       $0 unban CN"
    exit 1
fi

ACTION="${1,,}"  # lowercase
shift
COUNTRIES=("$@")

if [[ "$ACTION" != "ban" && "$ACTION" != "unban" ]]; then
    die "Unknown action '${ACTION}'. Must be 'ban' or 'unban'."
fi

# -----------------------------------------------------------------------------
# Locate the CrowdSec container (independent of project name / compose files)
# -----------------------------------------------------------------------------
CROWDSEC_ID=$(docker ps --filter "label=com.docker.compose.service=crowdsec" --filter "status=running" --format "{{.ID}}" | head -1)
if [ -z "$CROWDSEC_ID" ]; then
    die "CrowdSec container is not running. Start the stack first."
fi

CSCLI="docker exec ${CROWDSEC_ID} cscli"

# -----------------------------------------------------------------------------
# Process each country
# -----------------------------------------------------------------------------
TOTAL_OK=0
TOTAL_FAIL=0

for RAW_COUNTRY in "${COUNTRIES[@]}"; do
    COUNTRY="${RAW_COUNTRY^^}"  # uppercase

    if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
        error "Invalid country code '${COUNTRY}' — must be 2 letters (ISO 3166-1 alpha-2). Skipping."
        (( TOTAL_FAIL++ )) || true
        continue
    fi

    LOWER_COUNTRY="${COUNTRY,,}"
    IPDENY_URL="https://www.ipdeny.com/ipblocks/data/aggregated/${LOWER_COUNTRY}-aggregated.zone"

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD} Country: ${CYAN}${COUNTRY}${RESET}  │  Action: ${YELLOW}${ACTION^^}${RESET}"
    echo -e "${BOLD}══════════════════════════════════════════════${RESET}"

    info "Fetching IP ranges from IPDeny..."
    GEORANGES=$(mktemp /tmp/geoblock_ranges_XXXXXX.txt)
    HTTP_STATUS=$(curl -s -o "$GEORANGES" -w "%{http_code}" "${IPDENY_URL}")

    if [[ "$HTTP_STATUS" != "200" ]]; then
        error "Failed to fetch ranges for '${COUNTRY}' (HTTP ${HTTP_STATUS}). Unknown country code?"
        rm -f "$GEORANGES"
        (( TOTAL_FAIL++ )) || true
        continue
    fi

    RANGE_COUNT=$(wc -l < "$GEORANGES" | tr -d ' ')
    if [[ "$RANGE_COUNT" -eq 0 ]]; then
        warn "No IP ranges found for '${COUNTRY}'. Skipping."
        rm -f "$GEORANGES"
        (( TOTAL_FAIL++ )) || true
        continue
    fi

    info "Found ${RANGE_COUNT} CIDR ranges for ${COUNTRY}."

    OK=0
    FAIL=0

    if [[ "$ACTION" == "ban" ]]; then
        REASON="geoblock-country-${COUNTRY}"
        DURATION="8760h"  # 1 year

        info "Applying bans (reason: ${REASON}, duration: ${DURATION})..."

        # Build a shell script with all cscli commands and run it in one docker exec
        # (avoids per-CIDR exec overhead — e.g. 1500+ execs for some countries)
        TMPSCRIPT=$(mktemp /tmp/geoblock_ban_XXXXXX)
        echo '#!/bin/sh' > "$TMPSCRIPT"
        while IFS= read -r CIDR; do
            [[ -z "$CIDR" || "$CIDR" == \#* ]] && continue
            echo "cscli decisions add --range '${CIDR}' --reason '${REASON}' --duration '${DURATION}' --type ban" >> "$TMPSCRIPT"
            (( OK++ )) || true
        done < "$GEORANGES"

        # Stream docker exec output line-by-line to drive the progress bar.
        # cscli prints one line per range ("time=... level=info msg=Decision..."),
        # so each line ≈ one processed range.
        DONE=0
        progress_bar 0 "$OK" "banning ranges..."
        while IFS= read -r _line; do
            (( DONE++ )) || true
            progress_bar "$DONE" "$OK" "banning ranges..."
        done < <(docker exec -i "${CROWDSEC_ID}" sh < "$TMPSCRIPT" 2>&1)
        rm -f "$TMPSCRIPT"

        success "Sent ${OK} ban commands for ${COUNTRY}."
        [[ "$FAIL" -gt 0 ]] && warn "${FAIL} ranges failed."

    else
        REASON="geoblock-country-${COUNTRY}"

        info "Removing bans for reason '${REASON}'..."
        # Bulk delete by reason — much faster than per-CIDR deletes
        if $CSCLI decisions delete \
                --reason "$REASON" \
                > /dev/null 2>&1; then
            success "Removed all bans with reason '${REASON}' for ${COUNTRY}."
            (( OK++ )) || true
        else
            # Fallback: delete range-by-range in one docker exec
            warn "Bulk delete by reason failed or matched nothing — trying per-range fallback..."
            TMPSCRIPT=$(mktemp /tmp/geoblock_unban_XXXXXX)
            echo '#!/bin/sh' > "$TMPSCRIPT"
            while IFS= read -r CIDR; do
                [[ -z "$CIDR" || "$CIDR" == \#* ]] && continue
                echo "cscli decisions delete --range '${CIDR}'" >> "$TMPSCRIPT"
                (( OK++ )) || true
            done < "$GEORANGES"
            DONE=0
            progress_bar 0 "$OK" "unbanning ranges..."
            while IFS= read -r _line; do
                (( DONE++ )) || true
                progress_bar "$DONE" "$OK" "unbanning ranges..."
            done < <(docker exec -i "${CROWDSEC_ID}" sh < "$TMPSCRIPT" 2>&1)
            rm -f "$TMPSCRIPT"
            success "Sent unban for ${OK} ranges for ${COUNTRY}."
            warn "Ranges with no active decision are silently ignored."
        fi
    fi

    rm -f "$GEORANGES"
    (( TOTAL_OK++ )) || true
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
echo -e "${BOLD} Summary${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
echo -e "  Countries processed: ${TOTAL_OK}"
echo -e "  Countries skipped:   ${TOTAL_FAIL}"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    echo -e "  ${YELLOW}Some countries failed — check output above.${RESET}"
fi
echo ""
