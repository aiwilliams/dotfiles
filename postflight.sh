#!/usr/bin/env bash
# postflight.sh — Verify environment setup and fix what's missing.
# Safe to run anytime, not just after install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS="✓"
FAIL="✗"
WARN="!"
# SAFETY: commands[] strings are eval'd in the summary. Only add hardcoded
# strings with trusted variable expansions. Never include external input.
commands=()
manual_steps=()

pass() { echo "  $PASS $1"; }
fail() { echo "  $FAIL $1"; commands+=("$2"); }
manual() { echo "  $FAIL $1"; manual_steps+=("$2"); }
warn() { echo "  $WARN $1"; }
section() { echo ""; echo "$1"; }

source "$SCRIPT_DIR/lib/ssh-signing-key.sh"

# --- SSH Key ---

section "SSH Key"

if resolve_signing_key; then
  SSH_KEY="$SSH_SIGNING_KEY"
  pass "Key found: $SSH_KEY"
else
  SSH_KEY=""
  fail "No SSH key found" \
    "ssh-keygen -t ed25519 -f \"$HOME/.ssh/id_ed25519\" -C \"$(whoami)@$(hostname)\""
fi

# --- Git Signing ---

section "Git Commit Signing"

if [ "$(git config --global gpg.format 2>/dev/null)" = "ssh" ]; then
  pass "gpg.format = ssh"
else
  fail "gpg.format not set to ssh" \
    "git config --global gpg.format ssh"
fi

CONFIGURED_KEY="$(git config --global user.signingkey 2>/dev/null || true)"
if [ -n "$SSH_KEY" ] && [ "$CONFIGURED_KEY" = "$SSH_KEY.pub" ]; then
  pass "user.signingkey = $SSH_KEY.pub"
elif [ -n "$CONFIGURED_KEY" ] && [ -f "${CONFIGURED_KEY%.pub}" ]; then
  pass "user.signingkey = $CONFIGURED_KEY"
elif [ -n "$CONFIGURED_KEY" ]; then
  warn "user.signingkey set to $CONFIGURED_KEY but key file not found"
elif [ -n "$SSH_KEY" ]; then
  fail "user.signingkey not set" \
    "git config --global user.signingkey \"$SSH_KEY.pub\""
else
  fail "user.signingkey not set" \
    "source \"$SCRIPT_DIR/configure.sh\""
fi

if [ "$(git config --global commit.gpgsign 2>/dev/null)" = "true" ]; then
  pass "commit.gpgsign = true"
else
  fail "commit.gpgsign not enabled" \
    "git config --global commit.gpgsign true"
fi

if [ "$(git config --global tag.gpgsign 2>/dev/null)" = "true" ]; then
  pass "tag.gpgsign = true"
else
  fail "tag.gpgsign not enabled" \
    "git config --global tag.gpgsign true"
fi

ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
CONFIGURED_SIGNERS="$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || true)"
if [ "$CONFIGURED_SIGNERS" = "$ALLOWED_SIGNERS" ] && [ -f "$ALLOWED_SIGNERS" ]; then
  if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY.pub" ]; then
    LOCAL_KEY_DATA=$(awk '{print $2}' "$SSH_KEY.pub")
    if grep -qF "$LOCAL_KEY_DATA" "$ALLOWED_SIGNERS"; then
      pass "allowedSignersFile configured with current key"
    else
      fail "allowedSignersFile missing current key" \
        "source \"$SCRIPT_DIR/configure.sh\""
    fi
  else
    pass "allowedSignersFile configured"
  fi
else
  fail "allowedSignersFile not configured (local signature verification won't work)" \
    "source \"$SCRIPT_DIR/configure.sh\""
fi

# --- GitHub CLI ---

section "GitHub CLI"

if command -v gh &>/dev/null; then
  pass "gh installed"
else
  fail "gh not installed" "Run ./install.sh or install gh manually"
fi

if gh auth status &>/dev/null 2>&1; then
  ACCOUNT=$(gh auth status 2>&1 | grep "account" | head -1 | sed 's/.*account //' | awk '{print $1}')
  pass "Authenticated as $ACCOUNT"
else
  fail "Not authenticated" "gh auth login"
fi

# --- GitHub SSH Keys ---
# Verify keys are on GitHub without requiring admin token scopes.
# Authentication: test SSH connection to github.com
# Signing: make a test signature and verify it against GitHub's allowed signers

section "GitHub SSH Keys"

if [ -z "$SSH_KEY" ] || ! [ -f "$SSH_KEY.pub" ]; then
  warn "Skipping — no local SSH key to check"
else
  # Check authentication key: ssh to github.com returns exit 1 with a greeting on success
  SSH_OUTPUT=$(ssh -T -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true) # gitleaks:allow
  if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
    pass "Authentication key on GitHub"
  else
    manual "Authentication key not on GitHub" \
      "Add as Authentication Key at https://github.com/settings/ssh/new
        $(cat "$SSH_KEY.pub")"
  fi

  # Check signing key using the result from resolve_signing_key
  if [ "$SSH_SIGNING_KEY_ON_GITHUB" = "true" ]; then
    pass "Signing key on GitHub"
  else
    manual "Signing key not on GitHub" \
      "Add as Signing Key at https://github.com/settings/ssh/new
        $(cat "$SSH_KEY.pub")"
  fi
fi

# --- Summary ---

TOTAL=$(( ${#commands[@]} + ${#manual_steps[@]} ))
echo ""
if [ "$TOTAL" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi

echo "$TOTAL issue(s) found."

if [ ${#commands[@]} -gt 0 ]; then
  echo ""
  echo "Fixable with commands:"
  for cmd in "${commands[@]}"; do
    echo "  $cmd"
  done

  echo ""
  read -rp "Run all fix commands now? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    for cmd in "${commands[@]}"; do
      echo ""
      echo "→ $cmd"
      eval "$cmd"
    done
  fi
fi

if [ ${#manual_steps[@]} -gt 0 ]; then
  echo ""
  echo "Manual steps required:"
  for step in "${manual_steps[@]}"; do
    echo "  $step"
  done
fi
