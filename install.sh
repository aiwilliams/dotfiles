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

# Symlink db-worktree CLI to ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT_DIR/bin/db-worktree" "$HOME/.local/bin/db-worktree"
echo "Symlinked db-worktree to ~/.local/bin/db-worktree"
