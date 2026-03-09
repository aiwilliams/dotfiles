#!/usr/bin/env bash
# postflight.sh — Verify environment setup and fix what's missing.
# Safe to run anytime, not just after install.
set -euo pipefail

PASS="✓"
FAIL="✗"
WARN="!"
commands=()
manual_steps=()

pass() { echo "  $PASS $1"; }
fail() { echo "  $FAIL $1"; commands+=("$2"); }
manual() { echo "  $FAIL $1"; manual_steps+=("$2"); }
warn() { echo "  $WARN $1"; }
section() { echo ""; echo "$1"; }

SSH_KEY="$HOME/.ssh/id_ed25519_$(hostname)"
KEY_TITLE="$(whoami)@$(hostname)"

# --- SSH Key ---

section "SSH Key"

if [ -f "$SSH_KEY" ]; then
  pass "Key exists: $SSH_KEY"
else
  fail "Key missing: $SSH_KEY" \
    "ssh-keygen -t ed25519 -f \"$SSH_KEY\" -C \"$KEY_TITLE\""
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
if [ "$CONFIGURED_KEY" = "$SSH_KEY.pub" ]; then
  pass "user.signingkey = $SSH_KEY.pub"
elif [ -n "$CONFIGURED_KEY" ]; then
  warn "user.signingkey set to $CONFIGURED_KEY (expected $SSH_KEY.pub)"
else
  fail "user.signingkey not set" \
    "git config --global user.signingkey \"$SSH_KEY.pub\""
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
if [ -n "$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || true)" ] && [ -f "$ALLOWED_SIGNERS" ]; then
  pass "allowedSignersFile configured"
else
  fail "allowedSignersFile not configured (local signature verification won't work)" \
    "source ./configure.sh"
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

if ! [ -f "$SSH_KEY.pub" ]; then
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

  # Check signing key: create a test signature and verify via GitHub's API
  TMPFILE=$(mktemp)
  SIGFILE=$(mktemp)
  echo "postflight-test" > "$TMPFILE"
  if ssh-keygen -Y sign -f "$SSH_KEY" -n git "$TMPFILE" > /dev/null 2>&1; then
    # Use the API (read-only, no special scopes) to check signing keys.
    if gh auth status &>/dev/null 2>&1; then
      GH_LOGIN=$(gh auth status 2>&1 | grep "account" | head -1 | sed 's/.*account //' | awk '{print $1}')
      SIGNING_KEYS=$(gh api "users/$GH_LOGIN/ssh_signing_keys" --jq '.[].key' 2>/dev/null || true)
      LOCAL_KEY_DATA=$(awk '{print $2}' "$SSH_KEY.pub")
      if echo "$SIGNING_KEYS" | grep -qF "$LOCAL_KEY_DATA"; then
        pass "Signing key on GitHub"
      else
        manual "Signing key not on GitHub" \
          "Add as Signing Key at https://github.com/settings/ssh/new
        $(cat "$SSH_KEY.pub")"
      fi
    else
      warn "Signing key: cannot verify (gh not authenticated)"
    fi
  else
    warn "Signing key: ssh-keygen sign test failed"
  fi
  rm -f "$TMPFILE" "$SIGFILE" "${TMPFILE}.sig"
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
