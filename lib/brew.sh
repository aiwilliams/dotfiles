#!/usr/bin/env bash
# brew.sh — Homebrew helpers.

# Install formulae/casks that aren't already installed, silently skipping the rest.
brew_install() {
  local to_install=()
  for pkg in "$@"; do
    if ! brew list "$pkg" &>/dev/null; then
      to_install+=("$pkg")
    fi
  done
  if [ ${#to_install[@]} -gt 0 ]; then
    brew install "${to_install[@]}"
  fi
}

brew_install_cask() {
  local to_install=()
  for pkg in "$@"; do
    if ! brew list --cask "$pkg" &>/dev/null; then
      to_install+=("$pkg")
    fi
  done
  if [ ${#to_install[@]} -gt 0 ]; then
    brew install --cask "${to_install[@]}"
  fi
}
