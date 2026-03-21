#!/usr/bin/env bash
# mise.sh — Install mise and configure global tool versions.

set -euo pipefail

if command -v mise &>/dev/null; then
  echo "mise already installed, skipping."
else
  echo "Installing mise..."
  curl -fsSL https://mise.run | sh
fi

# Ensure mise is on PATH for this script
export PATH="$HOME/.local/bin:$PATH"

# Install global tools (idempotent — skips if already at latest)
mise use -g node@latest
mise use -g pnpm@latest

# Add mise-managed tools to PATH for subsequent scripts
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$HOME/.local/share/mise/shims:$PATH"
