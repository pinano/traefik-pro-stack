#!/bin/bash
set -e

# Change to root of the project
cd "$(dirname "$0")/.."

TARGET_TAG=$1

echo "Fetching latest tags from remote repository..."
git fetch --tags --force --quiet

if [ -n "$TARGET_TAG" ]; then
    # Add 'v' prefix if missing
    if ! [[ "$TARGET_TAG" == v* ]]; then
        TARGET_TAG="v$TARGET_TAG"
    fi
    if ! git show-ref --tags --verify --quiet "refs/tags/$TARGET_TAG"; then
        echo "Error: Tag '$TARGET_TAG' does not exist in the repository."
        exit 1
    fi
    LATEST_TAG=$TARGET_TAG
else
    # Find the latest version tag across the whole repo
    LATEST_TAG=$(git tag -l --sort=-v:refname | head -n 1)
fi

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No release tags found in the repository."
    exit 1
fi

# Find current checked out tag and commit
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
TARGET_COMMIT=$(git rev-parse "refs/tags/$LATEST_TAG^{commit}" 2>/dev/null || true)

if [ "$CURRENT_TAG" == "$LATEST_TAG" ] && [ "$CURRENT_COMMIT" == "$TARGET_COMMIT" ]; then
    echo "Status: You are already running the latest release ($LATEST_TAG)."
    exit 0
fi

echo "Update Available: $LATEST_TAG (Current: ${CURRENT_TAG:-not on a tag})"
read -p "Do you want to upgrade the codebase to $LATEST_TAG now? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled."
    exit 0
fi

# ==============================================================================
# POSTGRESQL UPGRADE DETECTION & MIGRATION
# ==============================================================================
# Detect if the target release updates PostgreSQL across major versions.
# If so, perform the database export and migration before switching codebase.
CUR_PG_IMG=$(grep -E '^\s*image:\s*postgres:' docker-compose-security.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"" | head -n 1 || true)
NEW_PG_IMG=$(git show "$LATEST_TAG:docker-compose-security.yaml" 2>/dev/null | grep -E '^\s*image:\s*postgres:' | awk '{print $2}' | tr -d "'\"" | head -n 1 || true)

CUR_PG_TAG="${CUR_PG_IMG#postgres:}"
NEW_PG_TAG="${NEW_PG_IMG#postgres:}"

CUR_PG_MAJOR=$(echo "$CUR_PG_TAG" | sed -E 's/^([0-9]+).*/\1/')
NEW_PG_MAJOR=$(echo "$NEW_PG_TAG" | sed -E 's/^([0-9]+).*/\1/')

if [ -n "$CUR_PG_MAJOR" ] && [ -n "$NEW_PG_MAJOR" ] && [ "$CUR_PG_MAJOR" != "$NEW_PG_MAJOR" ]; then
    if [ -d "./data/crowdsec/postgres" ]; then
        echo ""
        echo "🐘 PostgreSQL version update detected ($CUR_PG_TAG ➔ $NEW_PG_TAG)!"
        echo "📦 Initiating automatic database backup and migration..."
        ./scripts/upgrade-postgres.sh "$NEW_PG_TAG"
        echo "✅ PostgreSQL migration completed successfully."
        echo ""
    fi
fi

git checkout "$LATEST_TAG" --quiet
echo "Success: Codebase updated to $LATEST_TAG."
echo ""
read -p "Do you want to apply these changes now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebuilding and starting..."
    make rebuild
    make start
    echo "Stack updated successfully!"
else
    echo "Note: To apply these changes manually later, run:"
    echo "  make rebuild"
    echo "  make start"
fi
