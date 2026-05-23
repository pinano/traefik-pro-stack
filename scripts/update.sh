#!/bin/bash
set -e

echo "Fetching latest tags from remote repository..."
git fetch --tags --quiet

# Find the latest tag
LATEST_TAG=$(git describe --tags $(git rev-list --tags --max-count=1) 2>/dev/null || true)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No release tags found in the repository."
    exit 1
fi

# Find current checked out tag
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)

if [ "$CURRENT_TAG" == "$LATEST_TAG" ]; then
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

git checkout "$LATEST_TAG" --quiet
echo "Success: Codebase updated to $LATEST_TAG."
echo ""
read -p "Do you want to apply these changes and restart the stack now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Rebuilding and restarting..."
    make rebuild
    make restart
    echo "Stack updated successfully!"
else
    echo "Note: To apply these changes manually later, run:"
    echo "  make rebuild"
    echo "  make restart"
fi
