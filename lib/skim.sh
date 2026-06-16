#!/usr/bin/env bash
# skim.sh — Build and install skim, a keyboard-driven TUI for code reviews
# (https://github.com/ctdio/skim). It's written in Zig and ships no prebuilt
# binaries, so we build from source with a mise-managed Zig toolchain and drop
# the result in ~/.local/bin. Pairs with Graphite stacks (see dev-tools.sh).

set -euo pipefail

SKIM_REPO="https://github.com/ctdio/skim.git"
SKIM_SRC="$HOME/.local/src/skim"
SKIM_BIN="$HOME/.local/bin/skim"
SKIM_ZIG="0.15.1"   # skim pins this Zig version; check build.zig.zon on bumps

if ! command -v git &>/dev/null; then
  echo "Error: git is required to build skim." >&2
  return 1
fi
if ! command -v mise &>/dev/null; then
  echo "Error: mise is required for skim's Zig toolchain. Run lib/mise.sh first." >&2
  return 1
fi

# Ensure the pinned Zig toolchain is available (idempotent; no global pin).
mise install "zig@$SKIM_ZIG"

# Clone on first run; otherwise hard-reset to the latest upstream default branch.
# We never modify the tree, so discarding local state is safe and keeps rebuilds
# reproducible. zig-out/ is build output and survives the reset (untracked).
if [[ -d "$SKIM_SRC/.git" ]]; then
  echo "Updating skim source in $SKIM_SRC..."
  git -C "$SKIM_SRC" fetch --quiet origin
  skim_branch="$(git -C "$SKIM_SRC" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  git -C "$SKIM_SRC" reset --hard --quiet "origin/${skim_branch:-main}"
else
  echo "Cloning skim into $SKIM_SRC..."
  mkdir -p "$(dirname "$SKIM_SRC")"
  git clone --quiet "$SKIM_REPO" "$SKIM_SRC"
fi

echo "Building skim (ReleaseFast) with Zig $SKIM_ZIG..."
(cd "$SKIM_SRC" && mise exec "zig@$SKIM_ZIG" -- zig build -Doptimize=ReleaseFast)

mkdir -p "$HOME/.local/bin"
install -m 755 "$SKIM_SRC/zig-out/bin/skim" "$SKIM_BIN"

echo "Installed: skim -> $SKIM_BIN"
