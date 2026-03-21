#!/usr/bin/env bash
# mise.sh — Install mise and configure global tool versions.

set -euo pipefail

if command -v mise &>/dev/null; then
  echo "mise already installed, skipping."
else
  echo "Installing mise..."
  curl -fsSL https://mise.run | sh
fi

# Ensure mise is activated in current shell
eval "$("$HOME/.local/bin/mise" activate bash)"

# Install global tools (skip if already installed)
mise ls -g node &>/dev/null || mise use -g node@latest
mise ls -g pnpm &>/dev/null || mise use -g pnpm@latest
