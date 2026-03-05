#!/usr/bin/env bash
# projects.sh — Discover project repos under ~/projects.
#
# Layout convention: ~/projects/{visibility}/{project}/{repo}
# Worktrees live as siblings: ~/projects/{visibility}/{project}/{repo}-wtN

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/projects}"

# List repos that have at least one -wtN sibling directory.
# Output: one absolute path per line (the main repo dir, not the worktrees).
list_project_repos() {
  local -a repos=()
  for wt_dir in "$PROJECTS_ROOT"/*/*/*-wt[0-9]*; do
    [[ -d "$wt_dir" ]] || continue
    local base="${wt_dir%-wt[0-9]*}"
    [[ -d "$base/.git" || -f "$base/.git" ]] || continue
    # Deduplicate
    local already=false
    for r in "${repos[@]+"${repos[@]}"}"; do
      [[ "$r" == "$base" ]] && { already=true; break; }
    done
    $already || repos+=("$base")
  done
  printf '%s\n' "${repos[@]+"${repos[@]}"}"
}

# Ensure the cwd is inside a git worktree. If not, discover repos that use
# worktrees and let the user pick one. Sets the cwd to the chosen repo.
# Returns 0 on success, exits on failure/cancellation.
ensure_in_repo() {
  if git rev-parse --git-dir > /dev/null 2>&1; then
    return 0
  fi

  local -a repos=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && repos+=("$line")
  done < <(list_project_repos)

  if [[ ${#repos[@]} -eq 0 ]]; then
    echo "Error: not in a git repository and no worktree-enabled repos found under $PROJECTS_ROOT." >&2
    exit 1
  fi

  if [[ ${#repos[@]} -eq 1 ]]; then
    cd "${repos[0]}" || exit 1
    return 0
  fi

  if ! command -v fzf &>/dev/null; then
    echo "Error: not in a git repository. Available repos:" >&2
    printf '  %s\n' "${repos[@]}" >&2
    exit 1
  fi

  local selection
  selection=$(printf '%s\n' "${repos[@]}" | fzf --prompt="Select repo: ") || exit 0
  cd "$selection" || exit 1
}
