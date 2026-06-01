#!/bin/bash
# =============================================================================
# backup-db-dumps.sh — LXC Database Dump Script
# =============================================================================
# Runs directly on the LXC OS (not inside a container).
# Discovers all running MySQL/MariaDB/PostgreSQL containers and dumps them
# to BACKUP_DIR. Each container is processed independently — a failure in one
# does NOT abort the dumps for the others.
#
# Usage:
#   sudo /usr/local/bin/backup-db-dumps.sh
#
# Intended to run as a root cron job, 15 minutes before the Backrest
# backup plan is scheduled (e.g. 02:45 if Backrest runs at 03:00).
#
# Install:
#   sudo cp scripts/backup-db-dumps.sh /usr/local/bin/backup-db-dumps.sh
#   sudo chmod +x /usr/local/bin/backup-db-dumps.sh
# =============================================================================

set -uo pipefail

# Ensure script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (using sudo)." >&2
    exit 1
fi

BACKUP_DIR="/var/backups/incoming"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ERRORS=0

echo "=== Starting LXC DB Dumps: $TIMESTAMP ==="

# Ensure the backup directory exists
mkdir -p "$BACKUP_DIR"

# Clean previous dumps without deleting the directory itself to preserve the Docker bind mount inode
find "$BACKUP_DIR" -mindepth 1 -delete

DB_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -E "mysql|mariadb|postgres|db" || true)

if [ -z "$DB_CONTAINERS" ]; then
    echo "No database containers found. Skipping."
    exit 0
fi

for CONTAINER in $DB_CONTAINERS; do
    echo "--- Dumping: $CONTAINER ---"
    OUTPUT_FILE="$BACKUP_DIR/${CONTAINER}_${TIMESTAMP}.sql"

    # Detect MySQL/MariaDB dump tools (mariadb-dump is preferred in newer versions)
    DUMP_TOOL=""
    if docker exec "$CONTAINER" sh -c 'command -v mariadb-dump' >/dev/null 2>&1; then
        DUMP_TOOL="mariadb-dump"
    elif docker exec "$CONTAINER" sh -c 'command -v mysqldump' >/dev/null 2>&1; then
        DUMP_TOOL="mysqldump"
    fi

    if [ -n "$DUMP_TOOL" ]; then
        # Try with root password env var first (MYSQL_ROOT_PASSWORD / MARIADB_ROOT_PASSWORD),
        # using MYSQL_PWD inside the container shell to prevent CLI exposure and warning messages.
        # Fall back to no-password auth (e.g. containers using socket auth).
        if docker exec "$CONTAINER" sh -c \
            "MYSQL_PWD=\"\${MYSQL_ROOT_PASSWORD:-\${MARIADB_ROOT_PASSWORD:-}}\" $DUMP_TOOL --all-databases -u root" \
            > "$OUTPUT_FILE"; then
            echo "  OK: MySQL/MariaDB dump saved (root password)."
            chmod 600 "$OUTPUT_FILE"
        elif docker exec "$CONTAINER" sh -c \
            "$DUMP_TOOL --all-databases -u root" > "$OUTPUT_FILE"; then
            echo "  OK: MySQL/MariaDB dump saved (no password)."
            chmod 600 "$OUTPUT_FILE"
        else
            echo "  ERROR: $DUMP_TOOL failed for $CONTAINER"
            rm -f "$OUTPUT_FILE"
            ERRORS=$((ERRORS + 1))
        fi

    elif docker exec "$CONTAINER" sh -c 'command -v pg_dumpall' >/dev/null 2>&1; then
        if docker exec "$CONTAINER" pg_dumpall -U postgres > "$OUTPUT_FILE"; then
            echo "  OK: PostgreSQL dump saved."
            chmod 600 "$OUTPUT_FILE"
        else
            echo "  ERROR: pg_dumpall failed for $CONTAINER"
            rm -f "$OUTPUT_FILE"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "  SKIP: No supported dump tool found in $CONTAINER."
    fi
done

echo "=== DB Dumps Completed. Errors: $ERRORS ==="
exit $ERRORS
