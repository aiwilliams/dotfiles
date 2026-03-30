#!/usr/bin/env bash
# clickhouse.sh — Shared ClickHouse function library for per-worktree database isolation.
# Sourced (not executed) by wt-plugin-clickhouse.sh.

CH_HOST=localhost
CH_TCP_PORT=9000
CH_HTTP_PORT=8123

# --------------------------------------------------------------------------
# Low-level helpers
# --------------------------------------------------------------------------

ch_sanitize_branch_name() {
  local branch="$1"
  echo "$branch" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/_/g' \
    | sed 's/__*/_/g' \
    | sed 's/^_//;s/_$//' \
    | cut -c1-50
}

ch_exec() {
  local sql="$1"
  clickhouse client --host "$CH_HOST" --port "$CH_TCP_PORT" -q "$sql"
}

ch_db_exists() {
  local dbname="$1"
  local result
  result=$(ch_exec "SELECT 1 FROM system.databases WHERE name = '${dbname}'")
  [[ "$result" == "1" ]]
}

ch_create_db() {
  local dbname="$1"
  if ch_db_exists "$dbname"; then
    echo "Database '$dbname' already exists, skipping."
    return 0
  fi
  echo "Creating database '$dbname'..."
  ch_exec "CREATE DATABASE \"$dbname\""
}

ch_clone_db() {
  local source="$1"
  local target="$2"

  if ch_db_exists "$target"; then
    echo "Database '$target' already exists, skipping."
    return 0
  fi

  if ! ch_db_exists "$source"; then
    echo "Source database '$source' does not exist. Creating empty database instead."
    ch_create_db "$target"
    return 0
  fi

  echo "Cloning '$source' -> '$target'..."
  ch_exec "CREATE DATABASE \"$target\""

  local tables
  tables=$(ch_exec "SHOW TABLES FROM \"$source\"")
  if [[ -z "$tables" ]]; then
    echo "  (no tables to clone)"
    return 0
  fi

  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    echo "  Cloning table '$table'..."
    if ! ch_exec "CREATE TABLE \"$target\".\"$table\" AS \"$source\".\"$table\"" \
      || ! ch_exec "INSERT INTO \"$target\".\"$table\" SELECT * FROM \"$source\".\"$table\""; then
      echo "Error: failed to clone table '$table'. Dropping incomplete database '$target'." >&2
      ch_exec "DROP DATABASE IF EXISTS \"$target\"" 2>/dev/null || true
      return 1
    fi
  done <<< "$tables"
}

ch_drop_db() {
  local dbname="$1"
  if ! ch_db_exists "$dbname"; then
    echo "Database '$dbname' does not exist, skipping."
    return 0
  fi
  echo "Dropping database '$dbname'..."
  ch_exec "DROP DATABASE \"$dbname\""
}

# --------------------------------------------------------------------------
# High-level functions
# --------------------------------------------------------------------------

ch_create_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  echo "==> Creating ClickHouse databases for '$branch' (sanitized: '$sanitized')"

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    ch_create_db "${prefix}_${sanitized}"
  done

  echo "==> Done."
}

ch_clone_worktree_dbs() {
  local branch="$1"
  local source_branch="${2:-main}"
  local sanitized source_sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")
  source_sanitized=$(ch_sanitize_branch_name "$source_branch")

  echo "==> Cloning ClickHouse databases from '$source_branch' -> '$branch'"

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    ch_clone_db "${prefix}_${source_sanitized}" "${prefix}_${sanitized}"
  done

  echo "==> Done."
}

ch_drop_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  echo "==> Dropping ClickHouse databases for '$branch' (sanitized: '$sanitized')"

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    ch_drop_db "${prefix}_${sanitized}"
  done

  echo "==> Done."
}

ch_status_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  echo "Branch:    $branch"
  echo "Sanitized: $sanitized"
  echo ""

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if ch_db_exists "$dbname"; then
      local tables
      tables=$(ch_exec "SELECT count() FROM system.tables WHERE database = '${dbname}'")
      local size
      size=$(ch_exec "SELECT formatReadableSize(sum(total_bytes)) FROM system.tables WHERE database = '${dbname}'" 2>/dev/null) || size="unknown"
      echo "Database '$dbname':"
      echo "  Tables: $tables"
      echo "  Size:   $size"
    else
      echo "Database '$dbname': MISSING"
    fi
  done
}

# --------------------------------------------------------------------------
# Backup / Restore
# --------------------------------------------------------------------------

ch_backup_worktree_dbs() {
  local branch="$1"
  local backup_subdir="$2"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  echo "==> Backing up ClickHouse databases for '$branch'"

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if ! ch_db_exists "$dbname"; then
      echo "Database '$dbname' does not exist, skipping."
      continue
    fi

    local db_backup_dir="${backup_subdir}/${dbname}.ch"
    mkdir -p "$db_backup_dir"

    local tables
    tables=$(ch_exec "SHOW TABLES FROM \"$dbname\"")
    if [[ -z "$tables" ]]; then
      echo "  '$dbname': no tables to backup."
      continue
    fi

    while IFS= read -r table; do
      [[ -z "$table" ]] && continue
      # Save schema
      ch_exec "SHOW CREATE TABLE \"$dbname\".\"$table\" FORMAT TabSeparatedRaw" \
        > "${db_backup_dir}/${table}.sql"
      # Save data in Native format (compact binary)
      ch_exec "SELECT * FROM \"$dbname\".\"$table\" FORMAT Native" \
        > "${db_backup_dir}/${table}.native"
      local size
      size=$(du -h "${db_backup_dir}/${table}.native" | cut -f1)
      echo "  ${dbname}.${table} (${size})"
    done <<< "$tables"
  done
}

ch_restore_worktree_dbs() {
  local branch="$1"
  local backup_subdir="$2"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  echo "==> Restoring ClickHouse databases for '$branch'"

  for prefix in "${CH_DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    local db_backup_dir="${backup_subdir}/${dbname}.ch"

    if [[ ! -d "$db_backup_dir" ]]; then
      echo "No backup for '$dbname', skipping."
      continue
    fi

    # Drop and recreate database
    if ch_db_exists "$dbname"; then
      echo "Dropping '$dbname'..."
      ch_exec "DROP DATABASE \"$dbname\""
    fi
    echo "Creating '$dbname'..."
    ch_exec "CREATE DATABASE \"$dbname\""

    # Restore each table
    for schema_file in "$db_backup_dir"/*.sql; do
      [[ -f "$schema_file" ]] || continue
      local table
      table=$(basename "$schema_file" .sql)
      local data_file="${db_backup_dir}/${table}.native"

      # Create table from schema (strip database prefix from CREATE TABLE statement)
      local create_sql
      create_sql=$(sed "s/\"${dbname}\"\\.//" "$schema_file")
      echo "  Restoring ${dbname}.${table}..."
      clickhouse client --host "$CH_HOST" --port "$CH_TCP_PORT" --database "$dbname" -q "$create_sql"

      # Restore data
      if [[ -f "$data_file" ]] && [[ -s "$data_file" ]]; then
        clickhouse client --host "$CH_HOST" --port "$CH_TCP_PORT" \
          -q "INSERT INTO \"$dbname\".\"$table\" FORMAT Native" < "$data_file"
      fi
    done
  done

  echo "==> Done."
}

# --------------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------------

ch_apply_env() {
  local env_file="$1"
  local branch="$2"
  local env_vars
  env_vars=$(ch_generate_env_vars "$branch")

  if [[ -f "$env_file" ]]; then
    local tmp
    tmp=$(mktemp)
    grep -v '^CLICKHOUSE_URL=\|^CLICKHOUSE_USERNAME=\|^CLICKHOUSE_PASSWORD=\|^CLICKHOUSE_DATABASE=' "$env_file" > "$tmp" || true
    printf '%s\n' "$(<"$tmp")" > "$tmp"
    echo "" >> "$tmp"
    echo "$env_vars" >> "$tmp"
    mv "$tmp" "$env_file"
  else
    mkdir -p "$(dirname "$env_file")"
    echo "$env_vars" > "$env_file"
  fi
}

ch_generate_env_vars() {
  local branch="$1"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")

  cat <<EOF
CLICKHOUSE_URL="http://${CH_HOST}:${CH_HTTP_PORT}"
CLICKHOUSE_USERNAME="default"
CLICKHOUSE_PASSWORD=""
CLICKHOUSE_DATABASE="${CH_DB_PREFIXES[0]}_${sanitized}"
EOF
}
