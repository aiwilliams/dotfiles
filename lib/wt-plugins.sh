#!/usr/bin/env bash
# wt-plugins.sh — Plugin loader and hook dispatcher for wt.
#
# Reads .wtrc from the main worktree root to determine which plugins are active.
# Each plugin is a file at lib/wt-plugin-<name>.sh defining wtp_<name>_<hook> functions.
#
# Plugin hooks (dispatched via wt_dispatch_hook):
#   create    <wt_id>                  — clone/create databases for a new worktree
#   remove    <wt_id>                  — drop databases when a worktree is removed
#   env       <env_file> <wt_id>       — write plugin-managed vars into .env
#   backup    <wt_id> <backup_subdir>  — dump data into the backup directory
#   restore   <wt_id> <backup_subdir>  — restore data from a backup directory
#   status    <wt_id>                  — print database status details
#   ps_header                          — return column header name (no args)
#   ps_data   <wt_id>                  — return column value for wt ps
#
# .wtrc format (shell-sourceable, committed to repo root):
#   WT_PLUGINS=(postgres clickhouse)
#   WT_POSTGRES_DB_PREFIXES=(platform vector)
#   WT_CLICKHOUSE_DB_PREFIXES=(analytics)

WT_PLUGINS=()
WT_BACKUP_DIR="${HOME}/.local/share/wt-backups"

# Sanitize a name for use as a database/directory identifier.
wt_sanitize_name() {
  local name="$1"
  echo "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/_/g' \
    | sed 's/__*/_/g' \
    | sed 's/^_//;s/_$//' \
    | cut -c1-50
}

# List available backups for a worktree id.
wt_list_backups() {
  local wt_id="$1"
  local sanitized
  sanitized=$(wt_sanitize_name "$wt_id")
  local backup_dir="${WT_BACKUP_DIR}/${sanitized}"

  [[ -d "$backup_dir" ]] || return 1

  for d in "$backup_dir"/*/; do
    [[ -d "$d" ]] || continue
    local ts
    ts=$(basename "$d")
    local label=""
    if [[ -f "$d/label" ]]; then
      label=" ($(cat "$d/label"))"
    fi
    local sizes=""
    for f in "$d"/*.dump; do
      [[ -f "$f" ]] || continue
      local name size
      name=$(basename "$f" .dump)
      size=$(du -h "$f" | cut -f1)
      sizes="${sizes} ${name}=${size}"
    done
    for f in "$d"/*.ch; do
      [[ -d "$f" ]] || continue
      local name size
      name=$(basename "$f" .ch)
      size=$(du -sh "$f" | cut -f1)
      sizes="${sizes} ${name}(ch)=${size}"
    done
    echo "${ts}${label} —${sizes}"
  done
}

wt_load_plugins() {
  local main_dir="$1"
  local wtrc="${main_dir}/.wtrc"

  WT_PLUGINS=()

  if [[ -f "$wtrc" ]]; then
    # shellcheck source=/dev/null
    if ! source "$wtrc"; then
      echo "Error: failed to source ${wtrc}" >&2
      exit 1
    fi
  fi

  local missing=0
  if [[ ${#WT_PLUGINS[@]} -gt 0 ]]; then
    for plugin in "${WT_PLUGINS[@]}"; do
      local plugin_file="${LIB_DIR}/wt-plugin-${plugin}.sh"
      if [[ -f "$plugin_file" ]]; then
        # shellcheck source=/dev/null
        source "$plugin_file"
      else
        echo "Error: plugin '${plugin}' not found at ${plugin_file}" >&2
        missing=1
      fi
    done
  fi

  if (( missing )); then
    echo "Fix WT_PLUGINS in ${wtrc} or install the missing plugin files." >&2
    exit 1
  fi
}

# Call a hook on all active plugins.
# On failure: for 'remove', continues to remaining plugins; for other hooks, stops.
# Usage: wt_dispatch_hook <hook> [args...]
wt_dispatch_hook() {
  local hook="$1"; shift
  local failed=0
  [[ ${#WT_PLUGINS[@]} -gt 0 ]] || return 0
  for plugin in "${WT_PLUGINS[@]}"; do
    local fn="wtp_${plugin}_${hook}"
    if declare -f "$fn" > /dev/null 2>&1; then
      if ! "$fn" "$@"; then
        echo "Error: plugin '${plugin}' failed during '${hook}' hook." >&2
        failed=1
        [[ "$hook" != "remove" ]] && return 1
      fi
    fi
  done
  return $failed
}

# Collect ps column headers from all plugins (tab-separated).
wt_ps_headers() {
  local headers=""
  [[ ${#WT_PLUGINS[@]} -gt 0 ]] || { printf '%s' "$headers"; return; }
  for plugin in "${WT_PLUGINS[@]}"; do
    local fn="wtp_${plugin}_ps_header"
    if declare -f "$fn" > /dev/null 2>&1; then
      local h
      h=$("$fn")
      headers="${headers}\t${h}"
    fi
  done
  printf '%s' "$headers"
}

# Collect ps column data for a worktree id (tab-separated).
# Catches per-plugin failures so wt ps doesn't abort.
wt_ps_data() {
  local wt_id="$1"
  local data=""
  [[ ${#WT_PLUGINS[@]} -gt 0 ]] || { printf '%s' "$data"; return; }
  for plugin in "${WT_PLUGINS[@]}"; do
    local fn="wtp_${plugin}_ps_data"
    if declare -f "$fn" > /dev/null 2>&1; then
      local d
      d=$("$fn" "$wt_id" 2>/dev/null) || d="err"
      data="${data}\t${d}"
    fi
  done
  printf '%s' "$data"
}
