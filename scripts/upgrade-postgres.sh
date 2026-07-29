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

DB_CONTAINER="stack-crowdsec-db-1"
DUMP_FILE="/tmp/crowdsec_pg_upgrade_dump.sql"

# Source .env to get DB credentials
if [ -f .env ]; then
  source .env
fi
DB_USER=${CROWDSEC_DB_USER:-crowdsec}
DB_NAME=${CROWDSEC_DB_NAME:-crowdsec}

echo "🔍 Checking if the current database container is healthy..."
if ! docker inspect -f '{{.State.Health.Status}}' $DB_CONTAINER 2>/dev/null | grep -q "healthy"; then
    echo "❌ ERROR: Container $DB_CONTAINER is not healthy or not running."
    echo "You must revert to the old PostgreSQL image version in docker-compose-security.yaml"
    echo "and run 'make start' so the database is running before you can upgrade."
    exit 1
fi

echo "📦 Exporting current database data..."
# Use -c to clean (drop) database objects before recreating them. 
# This prevents conflicts if CrowdSec initializes a fresh schema on boot.
docker exec $DB_CONTAINER pg_dump -c -U $DB_USER $DB_NAME > $DUMP_FILE
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

echo "🚀 Starting the stack to initialize the new database..."
make start

echo "⏳ Waiting for the new database to become ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while ! docker inspect -f '{{.State.Health.Status}}' $DB_CONTAINER 2>/dev/null | grep -q "healthy"; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ ERROR: New database container failed to become healthy."
        exit 1
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

echo "📥 Importing data into the new PostgreSQL $NEW_VERSION database..."
docker exec -i $DB_CONTAINER psql -U $DB_USER $DB_NAME < $DUMP_FILE

echo "🧹 Cleaning up temporary dump file..."
rm -f $DUMP_FILE

echo "✅ PostgreSQL upgrade completed successfully!"
