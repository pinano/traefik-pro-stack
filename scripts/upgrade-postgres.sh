#!/bin/bash
# ==============================================================================
# UPGRADE POSTGRESQL SCRIPT
# Safely upgrades PostgreSQL by dumping the data, backing up the data folder,
# and restoring the data into the new version container.
# ==============================================================================
set -e

# Change to root of the project
cd "$(dirname "$0")/.."

NEW_VERSION=$1
if [ -z "$NEW_VERSION" ]; then
    echo "❌ ERROR: No target PostgreSQL version specified."
    echo "Usage: make upgrade-postgres VERSION=<new-version>"
    echo "Example: make upgrade-postgres VERSION=18.4-alpine3.23"
    exit 1
fi

DUMP_FILE="/tmp/crowdsec_pg_upgrade_dump.sql"

# Cleanup temporary dump file on exit or interruption
cleanup() {
    rm -f "$DUMP_FILE"
}
trap cleanup EXIT INT TERM

# Source .env to get DB credentials
if [ -f .env ]; then
  source .env
fi
DB_USER=${CROWDSEC_DB_USER:-crowdsec}
DB_NAME=${CROWDSEC_DB_NAME:-crowdsec}

echo "🔍 Locating crowdsec-db container..."
DB_CONTAINER=$(docker ps -q --filter "label=com.docker.compose.service=crowdsec-db" --filter "status=running" | head -n 1)
if [ -z "$DB_CONTAINER" ]; then
    echo "❌ ERROR: crowdsec-db container is not running."
    echo "Please ensure the stack is running with 'make start' before upgrading."
    exit 1
fi

echo "🔍 Checking if the current database container is healthy..."
if ! docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null | grep -q "healthy"; then
    echo "❌ ERROR: Container $DB_CONTAINER is not healthy."
    echo "You must revert to the old PostgreSQL image version in docker-compose-security.yaml"
    echo "and run 'make start' so the database is running and healthy before you can upgrade."
    exit 1
fi

echo "📦 Exporting current database data..."
# Create dump file with strict 0600 permissions to protect database contents in /tmp
(umask 077 && : > "$DUMP_FILE")
chmod 600 "$DUMP_FILE"

# Use -c to clean (drop) database objects before recreating them. 
# This prevents conflicts if CrowdSec initializes a fresh schema on boot.
docker exec "$DB_CONTAINER" pg_dump -c -U "$DB_USER" "$DB_NAME" > "$DUMP_FILE"
echo "✅ Database exported successfully to $DUMP_FILE"

echo "🛑 Stopping the stack..."
make stop

echo "💾 Backing up old PostgreSQL data directory..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./data/crowdsec/postgres_backup_$TIMESTAMP"
if [ -d "./data/crowdsec/postgres" ]; then
    mv ./data/crowdsec/postgres "$BACKUP_DIR"
    echo "✅ Old data directory moved to $BACKUP_DIR"
else
    echo "⚠️ Warning: ./data/crowdsec/postgres not found. Skipping backup."
fi

echo "🔄 Updating docker-compose-security.yaml to version $NEW_VERSION..."
# Using Python for reliable YAML replacement without regex edge cases
python3 -c "
import sys, re
file_path = 'docker-compose-security.yaml'
with open(file_path, 'r') as f:
    content = f.read()

new_content = re.sub(r'image:\s*postgres:.*', f'image: postgres:{sys.argv[1]}', content)

with open(file_path, 'w') as f:
    f.write(new_content)
" "$NEW_VERSION"
echo "✅ Configuration updated."

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

echo "🚀 Starting new PostgreSQL container to initialize database..."
$COMPOSE_CMD -f docker-compose-security.yaml up -d crowdsec-db

echo "⏳ Waiting for the new database container to become ready..."
MAX_RETRIES=30
RETRY_COUNT=0
NEW_DB_CONTAINER=""
while true; do
    NEW_DB_CONTAINER=$(docker ps -q --filter "label=com.docker.compose.service=crowdsec-db" | head -n 1)
    if [ -n "$NEW_DB_CONTAINER" ] && docker inspect -f '{{.State.Health.Status}}' "$NEW_DB_CONTAINER" 2>/dev/null | grep -q "healthy"; then
        break
    fi
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ ERROR: New database container failed to become healthy."
        exit 1
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

echo "📥 Importing data into the new PostgreSQL $NEW_VERSION database..."
docker exec -i "$NEW_DB_CONTAINER" psql -U "$DB_USER" "$DB_NAME" < "$DUMP_FILE"
echo "✅ Data restored successfully."

echo "🧹 Cleaning up temporary dump file..."
rm -f $DUMP_FILE

echo "🚀 Starting the full stack..."
make start

echo "✅ PostgreSQL upgrade completed successfully!"
