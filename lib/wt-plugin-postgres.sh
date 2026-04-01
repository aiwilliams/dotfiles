#!/usr/bin/env bash
# wt-plugin-postgres.sh — PostgreSQL plugin for wt.
#
# Wraps lib/postgres.sh functions in the wt plugin interface.
# Requires WT_POSTGRES_DB_PREFIXES in .wtrc.

if [[ ${#WT_POSTGRES_DB_PREFIXES[@]} -eq 0 ]]; then
  echo "Error: postgres plugin requires WT_POSTGRES_DB_PREFIXES in .wtrc" >&2
  return 1
fi

# shellcheck source=./postgres.sh
source "$LIB_DIR/postgres.sh"

DB_PREFIXES=("${WT_POSTGRES_DB_PREFIXES[@]}")

wtp_postgres_create() {
  local wt_id="$1"
  pg_clone_worktree_dbs "$wt_id"
}

wtp_postgres_remove() {
  local wt_id="$1"
  pg_drop_worktree_dbs "$wt_id"
}

wtp_postgres_env() {
  local env_file="$1"
  local wt_id="$2"
  pg_apply_env "$env_file" "$wt_id"
}

wtp_postgres_backup() {
  local wt_id="$1"
  local backup_subdir="$2"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$wt_id")

  for prefix in "${DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if ! pg_db_exists "$dbname"; then
      echo "Database '$dbname' does not exist, skipping."
      continue
    fi
    local dump_file="${backup_subdir}/${dbname}.dump"
    echo "Dumping '$dbname' -> $dump_file"
    PGPASSWORD="$PG_SUPERUSER" pg_dump \
      -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" \
      --format=custom --no-owner --no-acl \
      "$dbname" > "$dump_file"
  done
}

wtp_postgres_restore() {
  local wt_id="$1"
  local backup_subdir="$2"
  pg_restore_worktree_dbs "$wt_id" "$backup_subdir"
}

wtp_postgres_status() {
  local wt_id="$1"
  pg_status_worktree_dbs "$wt_id"
}

wtp_postgres_ps_header() {
  echo "POSTGRES"
}

wtp_postgres_ps_data() {
  local wt_id="$1"
  local sanitized="$wt_id"
  local db_conns=0
  local has_db=false

  for prefix in "${DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if pg_db_exists "$dbname" 2>/dev/null; then
      has_db=true
      local conns
      conns=$(pg_exec "SELECT count(*) FROM pg_stat_activity WHERE datname = '$dbname';" 2>/dev/null) || conns=0
      db_conns=$((db_conns + conns))
    fi
  done

  if $has_db; then
    echo "${db_conns} conn"
  else
    echo "-"
  fi
}
