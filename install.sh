#!/bin/bash
# dev-stack bootstrap - safe to run via:
#   curl -fsSL https://raw.githubusercontent.com/<you>/dev-stack/main/install.sh | bash
#
# This script's only job is to get the repo onto disk, then hand off
# to its own setup-env.sh - which is where all the real provisioning
# and dotfile-linking logic lives. Running this, or cloning the repo
# yourself and running ./setup-env.sh directly, behave identically.
#
# Override the destination or source with env vars, e.g.:
#   DEV_STACK_DIR=~/code/dev-stack curl -fsSL .../install.sh | bash
set -uo pipefail

REPO_URL="${DEV_STACK_REPO_URL:-https://github.com/<you>/dev-stack.git}"
INSTALL_DIR="${DEV_STACK_DIR:-$HOME/dev-stack}"

if ! command -v git >/dev/null 2>&1; then
    echo "git is required but wasn't found on PATH. Install it first, then re-run this." >&2
    exit 1
fi

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "==> dev-stack already cloned at $INSTALL_DIR, pulling latest"
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "==> Cloning dev-stack to $INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo "==> Handing off to setup-env.sh"
exec bash "$INSTALL_DIR/setup-env.sh" "$@"
