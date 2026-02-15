#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git config --global init.defaultBranch main
git config --global user.name "Adam Williams"

SSH_KEY="$HOME/.ssh/id_ed25519_$(hostname)"
if [ ! -f "$SSH_KEY" ]; then
  echo "Generating SSH key: $SSH_KEY"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -C "$(whoami)@$(hostname)"
  echo ""
  echo "Add this public key to your GitHub profile:"
  echo ""
  cat "$SSH_KEY.pub"
  echo ""
fi

# Platform-specific system packages + postgres
case "$(uname -s)" in
  Linux)
    "$SCRIPT_DIR/install-ubuntu.sh"
    ;;
  Darwin)
    "$SCRIPT_DIR/install-macos.sh"
    ;;
  *)
    echo "Unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

# mise (node, pnpm)
source "$SCRIPT_DIR/lib/mise.sh"

# Dev tools (claude, codex, graphite)
source "$SCRIPT_DIR/lib/dev-tools.sh"

# Symlink db-worktree CLI to ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT_DIR/bin/db-worktree" "$HOME/.local/bin/db-worktree"
ln -sf "$SCRIPT_DIR/bin/wt" "$HOME/.local/bin/wt"
echo "Symlinked db-worktree and wt to ~/.local/bin/"

# Claude Code MCP servers
source "$SCRIPT_DIR/lib/claude-mcp.sh"

# Symlink AGENTS.md to AI tool config directories
source "$SCRIPT_DIR/lib/agents.sh"
