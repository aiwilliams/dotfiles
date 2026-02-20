#!/usr/bin/env bash
# configure.sh — Apply shell config, symlinks, and hooks (no package installs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git config --global init.defaultBranch main

# Shell environment variables
if ! grep -qF "NX_TUI" "$HOME/.bashrc"; then
  echo '' >> "$HOME/.bashrc"
  echo '# Disable Nx TUI (incompatible with non-interactive shells)' >> "$HOME/.bashrc"
  echo 'export NX_TUI=false' >> "$HOME/.bashrc"
  echo "Added NX_TUI=false to ~/.bashrc"
fi

# Alias vim to nvim
if ! grep -qF "alias vim=" "$HOME/.bashrc"; then
  echo '' >> "$HOME/.bashrc"
  echo '# Use Neovim as vim' >> "$HOME/.bashrc"
  echo 'alias vim=nvim' >> "$HOME/.bashrc"
  echo "Added vim=nvim alias to ~/.bashrc"
fi

# pbcopy alias (OSC 52 clipboard, works over SSH + tmux)
if ! grep -qF "alias pbcopy=" "$HOME/.bashrc"; then
  echo '' >> "$HOME/.bashrc"
  echo '# pbcopy via OSC 52 (works over SSH + tmux)' >> "$HOME/.bashrc"
  echo 'alias pbcopy='\''printf "\033]52;c;%s\a" "$(base64)"'\''' >> "$HOME/.bashrc"
  echo "Added pbcopy alias to ~/.bashrc"
fi

# Symlink db-worktree CLI to ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT_DIR/bin/db-worktree" "$HOME/.local/bin/db-worktree"
ln -sf "$SCRIPT_DIR/bin/wt" "$HOME/.local/bin/wt"
echo "Symlinked db-worktree and wt to ~/.local/bin/"

# tmux config
mkdir -p "$HOME/.config/tmux"
ln -sf "$SCRIPT_DIR/config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
echo "Symlinked tmux.conf to ~/.config/tmux/"

# Zsh config
ln -sf "$SCRIPT_DIR/config/zsh/.zshrc" "$HOME/.zshrc"
ln -sf "$SCRIPT_DIR/config/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
echo "Symlinked .zshrc and .p10k.zsh to ~/"

# Set zsh as default shell (macOS already uses zsh)
if [ "$(uname -s)" = "Linux" ]; then
  ZSH_PATH="$(which zsh)"
  if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_PATH" ]; then
    echo "Changing default shell to zsh..."
    sudo chsh -s "$ZSH_PATH" "$USER"
  fi
fi

# Pre-commit hook
ln -sf "$SCRIPT_DIR/hooks/pre-commit" "$SCRIPT_DIR/.git/hooks/pre-commit"
echo "Installed pre-commit hook"

# Claude Code statusline
mkdir -p "$HOME/.claude"
ln -sf "$SCRIPT_DIR/config/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
echo "Symlinked statusline-command.sh to ~/.claude/"

# Claude Code MCP servers
source "$SCRIPT_DIR/lib/claude-mcp.sh"

# Symlink AGENTS.md to AI tool config directories
source "$SCRIPT_DIR/lib/agents.sh"
