#!/bin/bash
set -e

# Define backup directory and filename
BACKUP_DIR="backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/traefik-stack_${TIMESTAMP}.tar.gz"

echo "Creating backup..."

# Create backups directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Ensure we don't back up generated configs or previous acme backups
EXCLUDES=(
    "--exclude=./config/traefik/dynamic-config/*"
    "--exclude=./config/traefik/acme.json.*"
)

# Optional files that might not exist but should be backed up if they do
OPTIONAL_FILES=""
if [ -f "VERSION" ]; then
    OPTIONAL_FILES="$OPTIONAL_FILES VERSION"
fi
if [ -f "docker-compose-anubis-generated.yaml" ]; then
    OPTIONAL_FILES="$OPTIONAL_FILES docker-compose-anubis-generated.yaml"
fi
if [ -f "config/traefik/traefik-generated.yaml" ]; then
    OPTIONAL_FILES="$OPTIONAL_FILES config/traefik/traefik-generated.yaml"
fi

# Run tar
tar -czf "$BACKUP_FILE" "${EXCLUDES[@]}" .env domains.csv config/ $OPTIONAL_FILES

echo "Success: Backup created at $BACKUP_FILE"

# Clean up backups older than 7 days
RETENTION_DAYS=7
echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "traefik-stack_*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete

echo "To restore this backup later, run:"
echo "  make restore file=$BACKUP_FILE"
