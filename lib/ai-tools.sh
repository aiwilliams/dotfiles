#!/usr/bin/env bash
# ai-tools.sh — Install Claude Code and OpenAI Codex CLI tools.

set -euo pipefail

if ! command -v node &>/dev/null; then
  echo "Error: node is required. Install mise and node first." >&2
  return 1
fi

echo "Installing AI coding tools..."

if command -v claude &>/dev/null; then
  echo "Claude Code already installed ($(claude --version 2>&1 | head -1)), upgrading..."
fi
npm install -g @anthropic-ai/claude-code@latest

if command -v codex &>/dev/null; then
  echo "OpenAI Codex already installed, upgrading..."
fi
npm install -g @openai/codex@latest

echo "Installed: claude $(claude --version 2>&1 | head -1), codex $(codex --version 2>&1 | head -1)"
