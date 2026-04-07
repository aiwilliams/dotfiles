#!/usr/bin/env bash
# clickhouse.sh — Shared ClickHouse function library for per-worktree database isolation.
# Sourced (not executed) by wt-plugin-clickhouse.sh and install scripts.

CH_HOST=localhost
CH_TCP_PORT=9000
CH_HTTP_PORT=8123
CH_BIN="$HOME/.local/bin/clickhouse"
CH_DATA="$HOME/.local/share/clickhouse"

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

# Returns tab-separated name\tengine rows from system.tables, ordered so
# regular tables come before views and materialized views.
_ch_list_objects() {
  local dbname="$1"
  ch_exec "
    SELECT name, engine FROM system.tables
    WHERE database = '${dbname}'
    ORDER BY CASE engine
      WHEN 'MaterializedView' THEN 2
      WHEN 'View' THEN 1
      ELSE 0
    END, name
  "
}

# True if a CREATE MATERIALIZED VIEW statement uses a TO clause (routes data
# to an explicit target table and has no storage of its own).
_ch_mv_routes_to_table() {
  local create_sql="$1"
  local first_line="${create_sql%%$'\n'*}"
  [[ "$first_line" == *" TO "* ]]
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

  local table_info
  table_info=$(_ch_list_objects "$source")
  if [[ -z "$table_info" ]]; then
    echo "  (no tables to clone)"
    return 0
  fi

  while IFS=$'\t' read -r table engine; do
    [[ -z "$table" ]] && continue
    echo "  Cloning $engine '$table'..."

    case "$engine" in
      View|MaterializedView)
        # Recreate views/MVs from their DDL with database references rewritten.
        local create_sql
        create_sql=$(ch_exec "SHOW CREATE TABLE \"$source\".\"$table\" FORMAT TabSeparatedRaw")
        create_sql="${create_sql//$source/$target}"

        if ! ch_exec "$create_sql"; then
          echo "Error: failed to clone $engine '$table'. Dropping incomplete database '$target'." >&2
          ch_exec "DROP DATABASE IF EXISTS \"$target\"" 2>/dev/null || true
          return 1
        fi

        # Materialized views with implicit storage (no TO clause) hold their
        # own data — copy it so the clone has the same query results.
        if [[ "$engine" == "MaterializedView" ]] && ! _ch_mv_routes_to_table "$create_sql"; then
          ch_exec "INSERT INTO \"$target\".\"$table\" SELECT * FROM \"$source\".\"$table\"" 2>/dev/null || true
        fi
        ;;

      *)
        # Regular table: clone schema then copy data.
        if ! ch_exec "CREATE TABLE \"$target\".\"$table\" AS \"$source\".\"$table\"" \
          || ! ch_exec "INSERT INTO \"$target\".\"$table\" SELECT * FROM \"$source\".\"$table\""; then
          echo "Error: failed to clone table '$table'. Dropping incomplete database '$target'." >&2
          ch_exec "DROP DATABASE IF EXISTS \"$target\"" 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  done <<< "$table_info"
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

ch_cli() {
  local branch="$1"
  local prefix="${2:-${CH_DB_PREFIXES[0]}}"
  local sanitized
  sanitized=$(ch_sanitize_branch_name "$branch")
  local dbname="${prefix}_${sanitized}"

  if ! ch_db_exists "$dbname"; then
    echo "Error: database '$dbname' does not exist." >&2
    echo "Available prefixes: ${CH_DB_PREFIXES[*]}" >&2
    return 1
  fi

  echo "Connecting to $dbname..."
  exec clickhouse client --host "$CH_HOST" --port "$CH_TCP_PORT" --database "$dbname"
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

    local table_info
    table_info=$(_ch_list_objects "$dbname")
    if [[ -z "$table_info" ]]; then
      echo "  '$dbname': no tables to backup."
      continue
    fi

    while IFS=$'\t' read -r table engine; do
      [[ -z "$table" ]] && continue
      # Save schema
      ch_exec "SHOW CREATE TABLE \"$dbname\".\"$table\" FORMAT TabSeparatedRaw" \
        > "${db_backup_dir}/${table}.sql"

      # Views have no storage; TO-clause MVs route data to another table.
      # Only export data for objects that own their rows.
      local skip_data=false
      if [[ "$engine" == "View" ]]; then
        skip_data=true
      elif [[ "$engine" == "MaterializedView" ]]; then
        local create_sql
        create_sql=$(<"${db_backup_dir}/${table}.sql")
        _ch_mv_routes_to_table "$create_sql" && skip_data=true
      fi

      if $skip_data; then
        echo "  ${dbname}.${table} ($engine, schema only)"
      else
        ch_exec "SELECT * FROM \"$dbname\".\"$table\" FORMAT Native" \
          > "${db_backup_dir}/${table}.native"
        local size
        size=$(du -h "${db_backup_dir}/${table}.native" | cut -f1)
        echo "  ${dbname}.${table} (${size})"
      fi
    done <<< "$table_info"
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

    # Sort schema files so tables are restored before views and materialized
    # views (which may depend on them).
    local schema_tables=() schema_views=() schema_mvs=()
    for schema_file in "$db_backup_dir"/*.sql; do
      [[ -f "$schema_file" ]] || continue
      local first_line
      read -r first_line < "$schema_file"
      case "$first_line" in
        *"MATERIALIZED VIEW"*) schema_mvs+=("$schema_file") ;;
        *"CREATE VIEW"*)       schema_views+=("$schema_file") ;;
        *)                     schema_tables+=("$schema_file") ;;
      esac
    done

    for schema_file in "${schema_tables[@]}" "${schema_views[@]}" "${schema_mvs[@]}"; do
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

# --------------------------------------------------------------------------
# Installation
# --------------------------------------------------------------------------

ch_install_binary() {
  mkdir -p "$HOME/.local/bin" "$CH_DATA"

  if [[ -f "$CH_BIN" ]]; then
    echo "ClickHouse already installed at $CH_BIN, skipping download."
    return 0
  fi

  echo "Downloading ClickHouse binary..."
  local tmpdir
  tmpdir=$(mktemp -d)
  (cd "$tmpdir" && curl -fsSL https://clickhouse.com/ | sh)
  mv "$tmpdir/clickhouse" "$CH_BIN"
  chmod +x "$CH_BIN"
  rm -rf "$tmpdir"

  if [[ "$(uname)" == "Darwin" ]]; then
    xattr -d com.apple.quarantine "$CH_BIN" 2>/dev/null || true
  fi
}

ch_wait_for_start() {
  echo "Waiting for ClickHouse to start..."
  for _ in {1..30}; do
    if clickhouse client --host "$CH_HOST" --port "$CH_TCP_PORT" -q "SELECT 1" &>/dev/null; then
      echo "ClickHouse is running on ports ${CH_TCP_PORT} (TCP) / ${CH_HTTP_PORT} (HTTP)."
      return 0
    fi
    sleep 1
  done
  echo "Warning: ClickHouse did not start within 30s."
  return 1
}
