#!/usr/bin/env bash
# wt-plugin-clickhouse.sh — ClickHouse plugin for wt.
#
# Wraps lib/clickhouse.sh functions in the wt plugin interface.
# Requires WT_CLICKHOUSE_DB_PREFIXES in .wtrc.

if ! command -v clickhouse &>/dev/null; then
  echo "Error: clickhouse plugin requires 'clickhouse' client. Install: https://clickhouse.com/docs/install" >&2
  return 1
fi

if [[ ${#WT_CLICKHOUSE_DB_PREFIXES[@]} -eq 0 ]]; then
  echo "Error: clickhouse plugin requires WT_CLICKHOUSE_DB_PREFIXES in .wtrc" >&2
  return 1
fi

# shellcheck source=./clickhouse.sh
source "$LIB_DIR/clickhouse.sh"

CH_DB_PREFIXES=("${WT_CLICKHOUSE_DB_PREFIXES[@]}")

wtp_clickhouse_create() {
  local wt_id="$1"
  ch_clone_worktree_dbs "$wt_id"
}

wtp_clickhouse_remove() {
  local wt_id="$1"
  ch_drop_worktree_dbs "$wt_id"
}

wtp_clickhouse_env() {
  local env_file="$1"
  local wt_id="$2"
  ch_apply_env "$env_file" "$wt_id"
}

wtp_clickhouse_agent_env() {
  local agent_env_file="$1"
  local wt_id="$2"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$wt_id")
  cat >> "$agent_env_file" <<EOF
CLICKHOUSE_URL="http://${CH_HOST}:${CH_HTTP_PORT}"
CLICKHOUSE_USERNAME="default"
CLICKHOUSE_PASSWORD=""
CLICKHOUSE_DATABASE="${CH_DB_PREFIXES[0]}_${sanitized}"
EOF
}

wtp_clickhouse_backup() {
  local wt_id="$1"
  local backup_subdir="$2"
  ch_backup_worktree_dbs "$wt_id" "$backup_subdir"
}

wtp_clickhouse_restore() {
  local wt_id="$1"
  local backup_subdir="$2"
  ch_restore_worktree_dbs "$wt_id" "$backup_subdir"
}

wtp_clickhouse_status() {
  local wt_id="$1"
  ch_status_worktree_dbs "$wt_id"
}

wtp_clickhouse_ps_header() {
  echo "CLICKHOUSE"
}

wtp_clickhouse_ps_data() {
  local wt_id="$1"
  local sanitized="$wt_id"
  local has_db=false
  local table_count=0

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if ch_db_exists "$dbname" 2>/dev/null; then
      has_db=true
      local count
      count=$(ch_exec "SELECT count() FROM system.tables WHERE database = '${dbname}'" 2>/dev/null) || count=0
      table_count=$((table_count + count))
    fi
  done

  if $has_db; then
    echo "${table_count} tbl"
  else
    echo "-"
  fi
}
