#!/bin/bash
set -euo pipefail

# Confirm that the $update-docs reconciliation has been run for the current HEAD.
# This does not run the agent skill; it records the clean commit that was checked
# after the docs pass so release.sh can refuse stale or missing confirmations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT_FILE="$PROJECT_DIR/.build/update-docs-preflight"

status=$(git -C "$PROJECT_DIR" status --porcelain)
if [[ -n "$status" ]]; then
    echo "Error: Worktree has uncommitted changes."
    echo "Run \$update-docs, commit any resulting changes, then rerun this script."
    exit 1
fi

commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
mkdir -p "$(dirname "$PREFLIGHT_FILE")"
{
    echo "skill=update-docs"
    echo "commit=$commit"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PREFLIGHT_FILE"

echo "Confirmed \$update-docs preflight for $commit"
