#!/bin/bash
set -e

BACKUP_FILE=$1

if [ -z "$BACKUP_FILE" ]; then
    echo "Error: Please specify a backup file to restore."
    echo "Usage: make restore file=backups/traefik-stack_YYYYMMDD_HHMMSS.tar.gz"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file '$BACKUP_FILE' not found."
    exit 1
fi

echo "⚠️  WARNING: Restoring a backup will overwrite your current configuration!"
read -p "Are you sure you want to restore from $BACKUP_FILE? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Restore aborted."
    exit 0
fi

echo "Extracting backup..."
tar -xzf "$BACKUP_FILE"

echo "Restoring strict security permissions..."
if [ -f ".env" ]; then
    chmod 600 .env
fi
if [ -f "config/traefik/acme.json" ]; then
    chmod 600 config/traefik/acme.json
fi

echo "Success: Stack configuration restored from $BACKUP_FILE."
echo "Note: You should restart the stack for changes to take effect:"
echo "  make restart"
