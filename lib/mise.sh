#!/usr/bin/env bash
# mise.sh — Install mise and configure global tool versions.

set -euo pipefail

if command -v mise &>/dev/null; then
  echo "mise already installed; updating to latest..."
  # Keep mise current so its bundled aqua registry knows up-to-date asset
  # names (e.g. pnpm's renamed pnpm-darwin-arm64.tar.gz). Both machines
  # install mise via mise.run below, so self-update is the right mechanism.
  mise self-update -y
else
  echo "Installing mise..."
  curl -fsSL https://mise.run | sh
fi

# Ensure mise is on PATH for this script
export PATH="$HOME/.local/bin:$PATH"

# Install global tools (idempotent — skips if already at latest)
mise use -g node@latest
mise use -g pnpm@latest
# bun powers the env-init/env-revert helpers invoked by `wt env-init`.
mise use -g bun@latest
# Pinned to the 3.13 series: python@latest currently resolves to a freethreaded
# 3.14 build from python-build-standalone that installs without a lib/ directory.
mise use -g python@3.13
mise use -g uv@latest

# Add mise-managed tools to PATH for subsequent scripts
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$HOME/.local/share/mise/shims:$PATH"
