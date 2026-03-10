#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ssh-signing-key.sh"
if ! resolve_signing_key; then
  echo "No SSH key found."
  read -rp "Generate a new key? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    SSH_KEY="$HOME/.ssh/id_ed25519_$(hostname)"
    echo "Generating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C "$(whoami)@$(hostname)"
  fi
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

# Neovim (LazyVim)
source "$SCRIPT_DIR/lib/neovim.sh"

# Zsh (Oh My Zsh, plugins, Powerlevel10k)
source "$SCRIPT_DIR/lib/zsh.sh"

# Shell config, symlinks, hooks
source "$SCRIPT_DIR/configure.sh"

echo ""
echo "Install complete. Run ./postflight.sh to verify GitHub SSH keys and commit signing."
