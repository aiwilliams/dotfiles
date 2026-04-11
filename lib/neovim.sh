#!/usr/bin/env bash
# neovim.sh — Install LazyVim dependencies and symlink config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/brew.sh"

echo "Setting up Neovim (LazyVim)..."

# --- Neovim ---

case "$(uname -s)" in
  Darwin)
    # brew handles version tracking and upgrades.
    brew_install neovim
    ;;
  Linux)
    # apt's neovim is usually too old for LazyVim — install the latest stable
    # tarball from GitHub, but only when it's actually newer than what's
    # already on disk so re-runs don't churn.
    NVIM_LATEST=$(curl -s https://api.github.com/repos/neovim/neovim/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    CURRENT_NVIM_VERSION=$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//' || echo "0.0.0")
    if [ -z "$NVIM_LATEST" ]; then
      echo "Warning: could not determine latest Neovim version; skipping." >&2
    elif [ "$CURRENT_NVIM_VERSION" = "$NVIM_LATEST" ] \
      || [ "$(printf '%s\n%s\n' "$NVIM_LATEST" "$CURRENT_NVIM_VERSION" | sort -V | tail -1)" = "$CURRENT_NVIM_VERSION" ]; then
      echo "Neovim v${CURRENT_NVIM_VERSION} is up to date (latest: v${NVIM_LATEST}), skipping."
    else
      echo "Installing Neovim v${NVIM_LATEST} (current: ${CURRENT_NVIM_VERSION})..."
      # Remove apt neovim to avoid version conflicts
      if dpkg -l neovim &>/dev/null; then
        sudo apt-get remove -y neovim
      fi
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64)  NVIM_ARCH="x86_64" ;;
        aarch64) NVIM_ARCH="arm64" ;;
        *) echo "Unsupported architecture: $ARCH" >&2; return 1 ;;
      esac
      curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NVIM_LATEST}/nvim-linux-${NVIM_ARCH}.tar.gz" \
        | sudo tar xzf - -C /opt
      sudo ln -sf "/opt/nvim-linux-${NVIM_ARCH}/bin/nvim" /usr/local/bin/nvim
    fi
    ;;
esac

# --- LazyVim dependencies ---

case "$(uname -s)" in
  Linux)
    # ripgrep + fd
    sudo apt-get install -y ripgrep fd-find

    # lazygit (not in default Ubuntu repos)
    if ! command -v lazygit &>/dev/null; then
      echo "Installing lazygit..."
      LAZYGIT_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64) LAZYGIT_ARCH="x86_64" ;;
        aarch64|arm64) LAZYGIT_ARCH="arm64" ;;
        *) echo "Unsupported architecture: $ARCH" >&2; return 1 ;;
      esac
      curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz" \
        | sudo tar xzf - -C /usr/local/bin lazygit
    fi

    # JetBrainsMono Nerd Font
    FONT_DIR="$HOME/.local/share/fonts"
    if [ ! -d "$FONT_DIR/JetBrainsMonoNerdFont" ]; then
      echo "Installing JetBrainsMono Nerd Font..."
      mkdir -p "$FONT_DIR/JetBrainsMonoNerdFont"
      FONT_VERSION=$(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest | grep '"tag_name"' | sed 's/.*"\(.*\)".*/\1/')
      curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/JetBrainsMono.tar.xz" \
        | tar xJf - -C "$FONT_DIR/JetBrainsMonoNerdFont"
      fc-cache -f "$FONT_DIR"
    fi
    ;;

  Darwin)
    brew_install ripgrep fd lazygit
    brew_install_cask font-jetbrains-mono-nerd-font
    ;;
esac

# Symlink config
mkdir -p "$HOME/.config"
if [ -d "$HOME/.config/nvim" ] && [ ! -L "$HOME/.config/nvim" ]; then
  echo "Backing up existing ~/.config/nvim to ~/.config/nvim.bak"
  mv "$HOME/.config/nvim" "$HOME/.config/nvim.bak"
fi
ln -sfn "$SCRIPT_DIR/config/nvim" "$HOME/.config/nvim"

echo "Neovim (LazyVim) setup complete."
echo "  config: ~/.config/nvim -> $SCRIPT_DIR/config/nvim"
