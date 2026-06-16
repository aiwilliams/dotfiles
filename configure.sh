#!/usr/bin/env bash
# configure.sh — Apply shell config, symlinks, and hooks (no package installs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git config --global init.defaultBranch main

# Commit signing with SSH key
source "$SCRIPT_DIR/lib/ssh-signing-key.sh"
if resolve_signing_key; then
  SSH_KEY="$SSH_SIGNING_KEY"

  # Detect agent-based signing (e.g. 1Password): signingkey is a raw public key
  # string rather than a file path, and gpg.ssh.program is already configured.
  SSH_PROGRAM="$(git config --global gpg.ssh.program 2>/dev/null || true)"
  if [ -n "$SSH_PROGRAM" ] && [[ "$SSH_KEY" == ssh-* || "$SSH_KEY" == ecdsa-* ]]; then
    # Agent-based setup (1Password, etc.) — preserve existing config
    git config --global gpg.format ssh
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    PUBKEY="$SSH_KEY"
  else
    # File-based key
    git config --global gpg.format ssh
    git config --global user.signingkey "$SSH_KEY.pub"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    PUBKEY=""
    if [ -f "$SSH_KEY.pub" ]; then
      PUBKEY="$(cat "$SSH_KEY.pub")"
    fi
  fi

  # Allowed signers file for local signature verification
  ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
  GIT_EMAIL="$(git config --global user.email || true)"
  if [ -z "$GIT_EMAIL" ]; then
    echo "WARNING: git user.email not set, skipping allowed signers setup"
    echo "  Run: git config --global user.email you@example.com" # gitleaks:allow
    echo "  Then re-run ./configure.sh to enable local signature verification"
  elif [ -z "$PUBKEY" ]; then
    echo "WARNING: Could not determine public key, skipping allowed signers setup"
  else
    SIGNING_EMAILS_FILE="$HOME/.config/git/signing-emails"
    EMAILS=("$GIT_EMAIL")
    if [ -f "$SIGNING_EMAILS_FILE" ]; then
      while IFS= read -r email; do
        [ -n "$email" ] && EMAILS+=("$email")
      done < "$SIGNING_EMAILS_FILE"
    fi
    for email in "${EMAILS[@]}"; do
      if [ ! -f "$ALLOWED_SIGNERS" ] || ! grep -qF "$email $PUBKEY" "$ALLOWED_SIGNERS"; then
        echo "$email $PUBKEY" >> "$ALLOWED_SIGNERS"
        echo "  Added allowed signer for $email"
      fi
    done
    if [ ! -f "$SIGNING_EMAILS_FILE" ]; then
      echo "  Tip: Add extra emails to ~/.config/git/signing-emails for repos that use a different user.email"
    fi
    chmod 644 "$ALLOWED_SIGNERS"
    git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"
  fi

  echo "Configured git commit signing with ${SSH_PROGRAM:+$SSH_PROGRAM + }$SSH_KEY"
  if [ "$SSH_SIGNING_KEY_ON_GITHUB" = "false" ]; then
    echo "Note: This key is not yet registered as a signing key on GitHub"
    echo "  Add it at https://github.com/settings/ssh/new"
    if [ -n "$PUBKEY" ]; then
      echo "  Public key:"
      echo "  $PUBKEY"
    fi
  fi
else
  echo "WARNING: No SSH key found, skipping commit signing setup"
  echo "  Generate one with: ssh-keygen -t ed25519"
  echo "  Then re-run ./configure.sh"
fi

# Symlink db-worktree CLI to ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT_DIR/bin/db-worktree" "$HOME/.local/bin/db-worktree"
ln -sf "$SCRIPT_DIR/bin/wt" "$HOME/.local/bin/wt"
ln -sf "$SCRIPT_DIR/bin/pg" "$HOME/.local/bin/pg"
ln -sf "$SCRIPT_DIR/bin/cmux-ws" "$HOME/.local/bin/cmux-ws"
ln -sf "$SCRIPT_DIR/bin/syshealth" "$HOME/.local/bin/syshealth"
ln -sf "$SCRIPT_DIR/bin/scope" "$HOME/.local/bin/scope"
ln -sf "$SCRIPT_DIR/bin/nxs" "$HOME/.local/bin/nxs"
ln -sf "$SCRIPT_DIR/bin/tsgo-shim" "$HOME/.local/bin/tsgo-shim"
echo "Symlinked db-worktree, wt, pg, cmux-ws, syshealth, scope, nxs, tsgo-shim to ~/.local/bin/"

# tmux config
mkdir -p "$HOME/.config/tmux"
ln -sf "$SCRIPT_DIR/config/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf"
echo "Symlinked tmux.conf to ~/.config/tmux/"

# Zsh config
ln -sf "$SCRIPT_DIR/config/zsh/.zshenv" "$HOME/.zshenv"
ln -sf "$SCRIPT_DIR/config/zsh/.zshrc" "$HOME/.zshrc"
ln -sf "$SCRIPT_DIR/config/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
ln -sfn "$SCRIPT_DIR/config/zsh/plugins/zmx" "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zmx"
echo "Symlinked .zshenv, .zshrc, .p10k.zsh, and zmx plugin to ~/"

# Set zsh as default shell (macOS already uses zsh)
if [ "$(uname -s)" = "Linux" ]; then
  ZSH_PATH="$(which zsh)"
  if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_PATH" ]; then
    echo "Changing default shell to zsh..."
    sudo chsh -s "$ZSH_PATH" "$USER"
  fi
fi

# Global gitignore
GLOBAL_GITIGNORE="$HOME/.config/git/ignore"
mkdir -p "$(dirname "$GLOBAL_GITIGNORE")"
for pattern in .env.agent .mise.local.toml .wtrc '**/.claude/settings.local.json' '**/.claude/scheduled_tasks.lock'; do
  if [ ! -f "$GLOBAL_GITIGNORE" ] || ! grep -qxF "$pattern" "$GLOBAL_GITIGNORE"; then
    echo "$pattern" >> "$GLOBAL_GITIGNORE"
  fi
done
echo "Configured global gitignore ($GLOBAL_GITIGNORE)"

# Pre-commit hook
ln -sf "$SCRIPT_DIR/hooks/pre-commit" "$SCRIPT_DIR/.git/hooks/pre-commit"
echo "Installed pre-commit hook"

# Claude Code statusline
mkdir -p "$HOME/.claude"
ln -sf "$SCRIPT_DIR/config/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi
jq '.statusLine = {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}' \
  "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
echo "Configured Claude Code statusline"

# The *-ansi themes render diff context and dimmed text from the terminal's
# bright-black ANSI slot, which collapses to near-invisible on dark Ghostty
# backgrounds. Normalize to the fixed-RGB equivalents (which carry their own
# contrast) while preserving each machine's light/dark preference.
jq '(.theme) |= (if . == "dark-ansi" then "dark" elif . == "light-ansi" then "light" else . end)' \
  "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
echo "Normalized Claude Code theme (no *-ansi)"

# Claude Code MCP servers
source "$SCRIPT_DIR/lib/claude-mcp.sh"

# Symlink AGENTS.md to AI tool config directories
source "$SCRIPT_DIR/lib/agents.sh"
