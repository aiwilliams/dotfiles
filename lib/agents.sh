#!/usr/bin/env bash
# agents.sh — Symlink AGENTS.md to AI tool config directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_MD="$SCRIPT_DIR/AGENTS.md"

mkdir -p "$HOME/.claude"
ln -sf "$AGENTS_MD" "$HOME/.claude/AGENTS.md"
echo "Symlinked AGENTS.md to ~/.claude/AGENTS.md"

mkdir -p "$HOME/.codex"
ln -sf "$AGENTS_MD" "$HOME/.codex/instructions.md"
echo "Symlinked AGENTS.md to ~/.codex/instructions.md"
