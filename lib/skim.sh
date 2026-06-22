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

# macOS 26+ (Tahoe) workaround. Zig 0.15.x cannot link against the macOS 26 SDK:
# its MachO linker can't follow that SDK's new libSystem reexport chain, so every
# libc symbol (_abort, _free, __availability_version_check, ...) comes up
# undefined and the build — including zig's own build runner — fails to link.
# skim pins Zig 0.15.1 and deliberately won't move to 0.16 (see build.zig.zon),
# so we sidestep the new SDK by pointing DEVELOPER_DIR at a throwaway tree that
# exposes only the newest pre-26 SDK we can find. Zig picks the highest-versioned
# SDK under DEVELOPER_DIR, and a binary linked against the 15.x SDK still runs on
# macOS 26. Remove this once skim (and vaxis) support a Zig that links the 26 SDK.
skim_devdir=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  sdk_major="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)" || true
  if [[ "${sdk_major:-0}" -ge 26 ]]; then
    old_sdk=""; old_ver=-1
    for sdk_root in \
      /Library/Developer/CommandLineTools/SDKs \
      "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs"; do
      [[ -d "$sdk_root" ]] || continue
      for sdk in "$sdk_root"/MacOSX*.sdk; do
        [[ -e "$sdk" ]] || continue
        ver="${sdk##*/MacOSX}"; ver="${ver%.sdk}"; maj="${ver%%.*}"
        [[ "$maj" =~ ^[0-9]+$ ]] || continue
        if (( maj < 26 && maj > old_ver )); then old_ver="$maj"; old_sdk="$sdk"; fi
      done
    done
    if [[ -n "$old_sdk" ]]; then
      echo "  macOS $(sw_vers -productVersion) SDK is too new for Zig $SKIM_ZIG;"
      echo "  building against $(basename "$old_sdk")."
      skim_devdir="$(mktemp -d)"
      mkdir -p "$skim_devdir/Platforms/MacOSX.platform/Developer/SDKs"
      ln -s "$old_sdk" "$skim_devdir/Platforms/MacOSX.platform/Developer/SDKs/$(basename "$old_sdk")"
    else
      echo "  WARNING: macOS SDK >= 26 detected but no older SDK found; the Zig" >&2
      echo "  build will likely fail to link. Install the Command Line Tools or" >&2
      echo "  an older MacOSX*.sdk and re-run." >&2
    fi
  fi
fi

if [[ -n "$skim_devdir" ]]; then
  (cd "$SKIM_SRC" && DEVELOPER_DIR="$skim_devdir" mise exec "zig@$SKIM_ZIG" -- zig build -Doptimize=ReleaseFast)
  rm -rf "$skim_devdir"
else
  (cd "$SKIM_SRC" && mise exec "zig@$SKIM_ZIG" -- zig build -Doptimize=ReleaseFast)
fi

mkdir -p "$HOME/.local/bin"
install -m 755 "$SKIM_SRC/zig-out/bin/skim" "$SKIM_BIN"

echo "Installed: skim -> $SKIM_BIN"
