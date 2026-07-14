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

# Codex and Graphite are both installed via Homebrew, not pnpm/npm: brew ships
# standalone prebuilt binaries that don't depend on any project's Node version,
# so they survive node upgrades. (npm/pnpm globals are scoped per node version
# under mise and silently vanish when node is bumped.) brew is installed in a
# separate step, so ensure it's on PATH here before use.
if ! command -v brew &>/dev/null; then
  for brew_bin in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew_bin" ]] && eval "$("$brew_bin" shellenv)" && break
  done
fi

# Codex — the Homebrew cask ships a native binary (macOS and Linux) and pulls in
# ripgrep. Avoids pnpm's global install, which does not reliably extract Codex's
# vendored native binary, leaving an empty vendor dir and a wrapper that crashes
# with ENOENT.
if ! command -v codex &>/dev/null; then
  echo "Installing Codex..."
  if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew not found; cannot install Codex." >&2
    return 1
  fi
  brew install codex
else
  echo "Codex already installed, skipping."
fi

# Graphite (stacked PRs) — brew formula ships a standalone prebuilt gt binary
# (gt-macos-* / gt-linux).
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
