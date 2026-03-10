#!/usr/bin/env bash
# ssh-signing-key.sh — Resolve which SSH key to use for git commit signing.
#
# Sets:
#   SSH_SIGNING_KEY           — path to private key (empty string on failure)
#   SSH_SIGNING_KEY_ON_GITHUB — "true" or "false"
#
# Returns 0 on success, 1 if no key could be resolved.

resolve_signing_key() {
  SSH_SIGNING_KEY=""
  SSH_SIGNING_KEY_ON_GITHUB="false"

  # 1. Already configured? Use it if the file exists.
  local configured
  configured="$(git config --global user.signingkey 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    # signingkey points to .pub; derive private key path
    local private_key="${configured%.pub}"
    if [ -f "$private_key" ]; then
      SSH_SIGNING_KEY="$private_key"
      _check_key_on_github "$private_key"
      return 0
    fi
  fi

  # 2. Collect local ed25519 keys (exclude .pub files and agent/cert files)
  local local_keys=""
  local local_key_count=0
  for pub in "$HOME"/.ssh/id_ed25519*.pub; do
    [ -f "$pub" ] || continue
    local priv="${pub%.pub}"
    [ -f "$priv" ] || continue
    if [ -n "$local_keys" ]; then
      local_keys="$local_keys"$'\n'"$priv"
    else
      local_keys="$priv"
    fi
    local_key_count=$((local_key_count + 1))
  done

  if [ "$local_key_count" -eq 0 ]; then
    return 1
  fi

  # 3. Match against GitHub signing keys
  local gh_signing_keys=""
  local have_gh="false"
  local github_matched=""
  local github_matched_count=0

  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    have_gh="true"
    local gh_login
    gh_login=$(gh auth status 2>&1 | grep "account" | head -1 | sed 's/.*account //' | awk '{print $1}')
    gh_signing_keys=$(gh api "users/$gh_login/ssh_signing_keys" --jq '.[].key' 2>/dev/null || true)
  fi

  local key
  while IFS= read -r key; do
    if [ "$have_gh" = "true" ] && [ -n "$gh_signing_keys" ]; then
      local key_data
      key_data=$(awk '{print $2}' "$key.pub")
      if echo "$gh_signing_keys" | grep -qF "$key_data"; then
        if [ -n "$github_matched" ]; then
          github_matched="$github_matched"$'\n'"$key"
        else
          github_matched="$key"
        fi
        github_matched_count=$((github_matched_count + 1))
      fi
    fi
  done <<< "$local_keys"

  # Prefer a key that's already on GitHub
  if [ "$github_matched_count" -eq 1 ]; then
    SSH_SIGNING_KEY="$github_matched"
    SSH_SIGNING_KEY_ON_GITHUB="true"
    return 0
  fi

  # 4. Single local key — use it
  if [ "$local_key_count" -eq 1 ]; then
    SSH_SIGNING_KEY="$local_keys"
    SSH_SIGNING_KEY_ON_GITHUB="false"
    if [ "$have_gh" = "true" ] && [ -n "$gh_signing_keys" ]; then
      echo "Note: $local_keys is not yet registered as a signing key on GitHub"
    fi
    return 0
  fi

  # 5. Multiple keys — prompt user to choose
  echo "Multiple SSH keys found. Select one for commit signing:"
  local i=1
  while IFS= read -r key; do
    local on_gh=""
    local key_data
    key_data=$(awk '{print $2}' "$key.pub")
    if [ -n "$gh_signing_keys" ] && echo "$gh_signing_keys" | grep -qF "$key_data"; then
      on_gh=" (on GitHub)"
    fi
    echo "  $i) $key$on_gh"
    i=$((i + 1))
  done <<< "$local_keys"

  local choice
  read -rp "Choice [1-$local_key_count]: " choice
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$local_key_count" ] 2>/dev/null; then
    SSH_SIGNING_KEY=$(echo "$local_keys" | sed -n "${choice}p")
    _check_key_on_github "$SSH_SIGNING_KEY"
    return 0
  else
    echo "Invalid choice" >&2
    return 1
  fi
}

# Check whether a key is registered as a signing key on GitHub.
# Sets SSH_SIGNING_KEY_ON_GITHUB.
_check_key_on_github() {
  local private_key="$1"
  SSH_SIGNING_KEY_ON_GITHUB="false"

  [ -f "$private_key.pub" ] || return 0

  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    local gh_login
    gh_login=$(gh auth status 2>&1 | grep "account" | head -1 | sed 's/.*account //' | awk '{print $1}')
    local signing_keys
    signing_keys=$(gh api "users/$gh_login/ssh_signing_keys" --jq '.[].key' 2>/dev/null || true)
    if [ -n "$signing_keys" ]; then
      local key_data
      key_data=$(awk '{print $2}' "$private_key.pub")
      if echo "$signing_keys" | grep -qF "$key_data"; then
        export SSH_SIGNING_KEY_ON_GITHUB="true"
      fi
    fi
  fi
}
