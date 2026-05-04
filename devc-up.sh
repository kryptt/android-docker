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

# The host home is on NFS with root_squash, so dockerd (real root) can't
# stat sockets under ~/.ssh/. Always point the container at a socket on
# local tmpfs (XDG_RUNTIME_DIR), reusing a dedicated agent across launches
# so we don't leak ssh-agent processes.
SSH_SOCK_PATH="${XDG_RUNTIME_DIR:-/tmp}/devc-ssh-agent.sock"
SSH_PID_PATH="${XDG_RUNTIME_DIR:-/tmp}/devc-ssh-agent.pid"

if [ -S "$SSH_SOCK_PATH" ] && [ -f "$SSH_PID_PATH" ] && kill -0 "$(cat "$SSH_PID_PATH")" 2>/dev/null; then
    :  # reuse the existing dedicated agent
else
    rm -f "$SSH_SOCK_PATH" "$SSH_PID_PATH"
    eval "$(ssh-agent -a "$SSH_SOCK_PATH" -s)" >/dev/null
    echo "$SSH_AGENT_PID" > "$SSH_PID_PATH"
    echo "Started ssh-agent at $SSH_SOCK_PATH (PID $SSH_AGENT_PID)."
    echo "Run 'SSH_AUTH_SOCK=$SSH_SOCK_PATH ssh-add' on the host to load keys."
fi

export SSH_AUTH_SOCK="$SSH_SOCK_PATH"

exec devcontainer up \
    --workspace-folder "$(cd "$(dirname "$0")" && pwd)" \
    --update-remote-user-uid-default never \
    "$@"
