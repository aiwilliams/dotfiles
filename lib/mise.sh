#!/usr/bin/env bash
# mise.sh — Install mise and configure global tool versions.

set -euo pipefail

if command -v mise &>/dev/null; then
  echo "mise already installed, skipping."
else
  echo "Installing mise..."
  curl -fsSL https://mise.run | sh
fi

# Ensure mise is activated in current shell
eval "$("$HOME/.local/bin/mise" activate bash)"

# Add mise activation to .bashrc if not already present
if ! grep -qF "mise activate" "$HOME/.bashrc"; then
  echo '' >> "$HOME/.bashrc"
  echo '# mise (tool version manager)' >> "$HOME/.bashrc"
  echo 'eval "$(~/.local/bin/mise activate bash)"' >> "$HOME/.bashrc"
  echo "Added mise activation to ~/.bashrc"
fi

# Install global tools
mise use -g node@latest
mise use -g pnpm@latest
