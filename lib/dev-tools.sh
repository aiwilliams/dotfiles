#!/usr/bin/env bash
# dev-tools.sh — Install dev tools (Claude Code, Codex, Graphite).

set -euo pipefail

if ! command -v node &>/dev/null; then
  echo "Error: node is required. Install mise and node first." >&2
  return 1
fi

echo "Installing dev tools..."

# Claude Code (native install)
curl -fsSL https://claude.ai/install.sh | bash

# Codex
npm install -g @openai/codex@latest

# Graphite (stacked PRs)
npm install -g @withgraphite/graphite-cli@stable

echo "Installed:"
echo "  claude $(claude --version 2>&1 | head -1)"
echo "  codex  $(codex --version 2>&1 | head -1)"
echo "  gt     $(gt --version 2>&1 | head -1)"
