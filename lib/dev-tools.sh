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
# Install the native binary directly, not via pnpm: pnpm's global install does
# not reliably extract Codex's vendored native binary, leaving an empty vendor
# dir and a wrapper that crashes with ENOENT. macOS uses the official Homebrew
# cask; other platforms fall back to npm, which handles the platform binary.
if ! command -v codex &>/dev/null; then
  echo "Installing Codex..."
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
    brew install codex
  else
    npm install -g @openai/codex@latest
  fi
else
  echo "Codex already installed, skipping."
fi

# Graphite (stacked PRs)
#
# Installed via Homebrew, not pnpm: the brew formula ships a standalone prebuilt
# gt binary (gt-macos-* / gt-linux), so it doesn't depend on any project's Node
# version. Works on macOS and Linux (Homebrew on Linux, set up in
# install-ubuntu.sh). brew is installed in a separate step, so ensure it's on
# PATH here before use.
if ! command -v brew &>/dev/null; then
  for brew_bin in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew_bin" ]] && eval "$("$brew_bin" shellenv)" && break
  done
fi

if ! command -v gt &>/dev/null; then
  echo "Installing Graphite..."
  if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew not found; cannot install Graphite (gt)." >&2
    return 1
  fi
  brew install withgraphite/tap/graphite
else
  echo "Graphite already installed, skipping."
fi

echo "Installed:"
echo "  claude $(claude --version 2>&1 | head -1)"
echo "  codex  $(codex --version 2>&1 | head -1)"
echo "  gt     $(gt --version 2>&1 | head -1)"
