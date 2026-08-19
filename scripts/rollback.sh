#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Fetching latest tags from remote repository..."
git fetch --tags --force --quiet

echo "Recent versions:"
TAGS=($(git tag -l --sort=-v:refname | head -n 10))

if [ ${#TAGS[@]} -eq 0 ]; then
    echo "Error: No release tags found in the repository."
    exit 1
fi

CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)

for i in "${!TAGS[@]}"; do
    if [ "${TAGS[$i]}" == "$CURRENT_TAG" ]; then
        echo "  $((i+1))) ${TAGS[$i]} (Current)"
    else
        echo "  $((i+1))) ${TAGS[$i]}"
    fi
done

echo ""
read -p "Select a version to rollback/update to (1-${#TAGS[@]}, or press Enter to cancel): " choice

if [[ -z "$choice" ]]; then
    echo "Cancelled."
    exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#TAGS[@]}" ]; then
    echo "Invalid choice. Aborting."
    exit 1
fi

SELECTED_TAG=${TAGS[$((choice-1))]}

if [ "$SELECTED_TAG" == "$CURRENT_TAG" ]; then
    echo "Status: You are already running $SELECTED_TAG."
    exit 0
fi

echo ""
echo "Selected Version: $SELECTED_TAG"
read -p "Are you sure you want to change the codebase to $SELECTED_TAG? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# ==============================================================================
# POSTGRESQL UPGRADE/DOWNGRADE DETECTION & MIGRATION
# ==============================================================================
CUR_PG_IMG=$(grep -E '^\s*image:\s*postgres:' docker-compose-security.yaml 2>/dev/null | awk '{print $2}' | tr -d "'"'" | head -n 1 || true)
NEW_PG_IMG=$(git show "$SELECTED_TAG:docker-compose-security.yaml" 2>/dev/null | grep -E '^\s*image:\s*postgres:' | awk '{print $2}' | tr -d "'"'" | head -n 1 || true)

CUR_PG_TAG="${CUR_PG_IMG#postgres:}"
NEW_PG_TAG="${NEW_PG_IMG#postgres:}"

CUR_PG_MAJOR=$(echo "$CUR_PG_TAG" | sed -E 's/^([0-9]+).*/\1/')
NEW_PG_MAJOR=$(echo "$NEW_PG_TAG" | sed -E 's/^([0-9]+).*/\1/')

if [ -n "$CUR_PG_MAJOR" ] && [ -n "$NEW_PG_MAJOR" ] && [ "$CUR_PG_MAJOR" != "$NEW_PG_MAJOR" ]; then
    if [ -d "./data/crowdsec/postgres" ]; then
        echo ""
        echo "🐘 PostgreSQL version change detected ($CUR_PG_TAG ➔ $NEW_PG_TAG)!"
        echo "📦 Initiating automatic database backup and migration..."
        ./scripts/upgrade-postgres.sh "$NEW_PG_TAG"
        echo "✅ PostgreSQL migration completed successfully."
        echo ""
    fi
fi

git checkout "$SELECTED_TAG" --quiet
echo "Success: Codebase changed to $SELECTED_TAG."
echo ""
read -p "Do you want to apply these changes and start the stack now? [y/N] " -n 1 -r
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

