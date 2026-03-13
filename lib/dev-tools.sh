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
if ! command -v codex &>/dev/null; then
  echo "Installing Codex..."
  npm install -g @openai/codex@latest
else
  echo "Codex already installed, skipping."
fi

# Graphite (stacked PRs)
if ! command -v gt &>/dev/null; then
  echo "Installing Graphite..."
  npm install -g @withgraphite/graphite-cli@stable
else
  echo "Graphite already installed, skipping."
fi

echo "Installed:"
echo "  claude $(claude --version 2>&1 | head -1)"
echo "  codex  $(codex --version 2>&1 | head -1)"
echo "  gt     $(gt --version 2>&1 | head -1)"
