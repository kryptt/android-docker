#!/usr/bin/env bash
set -euo pipefail

# Ensure GH_TOKEN is available for the devcontainer
if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN=$(gh auth token 2>/dev/null) || true
fi

if [ -z "${GH_TOKEN:-}" ]; then
    echo "Warning: Could not obtain GH_TOKEN. GitHub CLI will not be authenticated in the container."
    echo "Run 'gh auth login' on the host first, or export GH_TOKEN manually."
fi

export GH_TOKEN

exec devcontainer up \
    --workspace-folder "$(cd "$(dirname "$0")" && pwd)" \
    --update-remote-user-uid-default never \
    "$@"
