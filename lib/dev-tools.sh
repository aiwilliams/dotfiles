#!/usr/bin/env bash
# dev-tools.sh — Install dev tools (Claude Code, Codex, Graphite).

set -euo pipefail

if ! command -v node &>/dev/null; then
  echo "Error: node is required. Install mise and node first." >&2
  return 1
fi

echo "Setting up Claude Code..."

# Claude Code (native install)
if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
else
  echo "Claude Code already installed, skipping."
fi

# Codex
# Install the native binary directly, not via pnpm: pnpm's global install does
# not reliably extract Codex's vendored native binary, leaving an empty vendor
# dir and a wrapper that crashes with ENOENT. macOS uses the official Homebrew
# cask; other platforms fall back to npm, which handles the platform binary.
if ! command -v codex &>/dev/null; then
  echo "Installing Codex..."
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
    brew install codex
  else
    npm install -g @openai/codex@latest
  fi
else
  echo "Codex already installed, skipping."
fi

# Graphite (stacked PRs)
if ! command -v gt &>/dev/null; then
  echo "Installing Graphite..."
  pnpm add -g @withgraphite/graphite-cli@stable
else
  echo "Graphite already installed, skipping."
fi

echo "Installed:"
echo "  claude $(claude --version 2>&1 | head -1)"
echo "  codex  $(codex --version 2>&1 | head -1)"
echo "  gt     $(gt --version 2>&1 | head -1)"
