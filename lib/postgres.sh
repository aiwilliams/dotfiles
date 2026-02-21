#!/usr/bin/env bash
# postgres.sh — Shared PostgreSQL function library for per-worktree database isolation.
# Sourced (not executed) by install scripts and bin/db-worktree.

PG_PORT=5432
PG_SUPERUSER=postgres
DB_PREFIXES=(platform vector)

# --------------------------------------------------------------------------
# Low-level helpers
# --------------------------------------------------------------------------

pg_sanitize_branch_name() {
  local branch="$1"
  echo "$branch" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/_/g' \
    | sed 's/__*/_/g' \
    | sed 's/^_//;s/_$//' \
    | cut -c1-50
}

pg_exec() {
  local sql="$1"
  PGPASSWORD="$PG_SUPERUSER" psql -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" -tAc "$sql"
}

pg_exec_db() {
  local database="$1"
  local sql="$2"
  PGPASSWORD="$PG_SUPERUSER" psql -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" -d "$database" -tAc "$sql"
}

pg_user_exists() {
  local username="$1"
  local result
  result=$(pg_exec "SELECT 1 FROM pg_roles WHERE rolname = '$username';")
  [[ "$result" == "1" ]]
}

pg_db_exists() {
  local dbname="$1"
  local result
  result=$(pg_exec "SELECT 1 FROM pg_database WHERE datname = '$dbname';")
  [[ "$result" == "1" ]]
}

pg_create_user() {
  local username="$1"
  if pg_user_exists "$username"; then
    echo "User '$username' already exists, skipping."
    return 0
  fi
  echo "Creating user '$username'..."
  pg_exec "CREATE USER \"$username\" WITH LOGIN CREATEDB SUPERUSER PASSWORD '$username';"
}

pg_create_db() {
  local dbname="$1"
  local owner="$2"
  if pg_db_exists "$dbname"; then
    echo "Database '$dbname' already exists, skipping."
    return 0
  fi
  echo "Creating database '$dbname' owned by '$owner'..."
  pg_exec "CREATE DATABASE \"$dbname\" OWNER \"$owner\";"
  pg_exec_db "$dbname" "CREATE EXTENSION IF NOT EXISTS vector;"
}

pg_clone_db() {
  local source="$1"
  local target="$2"
  local owner="$3"

  if pg_db_exists "$target"; then
    echo "Database '$target' already exists, skipping."
    return 0
  fi

  if ! pg_db_exists "$source"; then
    echo "Source database '$source' does not exist. Creating empty database instead."
    pg_create_db "$target" "$owner"
    return 0
  fi

  echo "Terminating connections to '$source'..."
  pg_exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$source' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true

  echo "Cloning '$source' -> '$target'..."
  if pg_exec "CREATE DATABASE \"$target\" TEMPLATE \"$source\" OWNER \"$owner\";" 2>/dev/null; then
    echo "Cloned via TEMPLATE."
  else
    echo "TEMPLATE clone failed, falling back to pg_dump|psql..."
    pg_exec "CREATE DATABASE \"$target\" OWNER \"$owner\";"
    PGPASSWORD="$PG_SUPERUSER" pg_dump -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" "$source" \
      | PGPASSWORD="$PG_SUPERUSER" psql -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" -d "$target" > /dev/null 2>&1
  fi
}

pg_drop_db() {
  local dbname="$1"
  if ! pg_db_exists "$dbname"; then
    echo "Database '$dbname' does not exist, skipping."
    return 0
  fi
  echo "Terminating connections to '$dbname'..."
  pg_exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$dbname' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true
  echo "Dropping database '$dbname'..."
  pg_exec "DROP DATABASE \"$dbname\";"
}

pg_drop_user() {
  local username="$1"
  if ! pg_user_exists "$username"; then
    echo "User '$username' does not exist, skipping."
    return 0
  fi
  echo "Dropping user '$username'..."
  pg_exec "DROP USER \"$username\";"
}

# --------------------------------------------------------------------------
# High-level functions
# --------------------------------------------------------------------------

pg_create_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")

  echo "==> Creating worktree databases for branch '$branch' (sanitized: '$sanitized')"
  pg_create_user "$sanitized"

  for prefix in "${DB_PREFIXES[@]}"; do
    pg_create_db "${prefix}_${sanitized}" "$sanitized"
  done

  echo "==> Done."
}

pg_clone_worktree_dbs() {
  local branch="$1"
  local source_branch="${2:-main}"
  local sanitized source_sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")
  source_sanitized=$(pg_sanitize_branch_name "$source_branch")

  echo "==> Cloning worktree databases from '$source_branch' -> '$branch'"
  pg_create_user "$sanitized"

  for prefix in "${DB_PREFIXES[@]}"; do
    pg_clone_db "${prefix}_${source_sanitized}" "${prefix}_${sanitized}" "$sanitized"
  done

  echo "==> Done."
}

pg_drop_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")

  echo "==> Dropping worktree databases for branch '$branch' (sanitized: '$sanitized')"

  for prefix in "${DB_PREFIXES[@]}"; do
    pg_drop_db "${prefix}_${sanitized}"
  done

  pg_drop_user "$sanitized"
  echo "==> Done."
}

pg_list_worktree_dbs() {
  echo "Worktree databases:"
  pg_exec "SELECT datname FROM pg_database WHERE datname LIKE 'platform_%' OR datname LIKE 'vector_%' ORDER BY datname;"
}

pg_status_worktree_dbs() {
  local branch="$1"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")

  echo "Branch:    $branch"
  echo "Sanitized: $sanitized"
  echo ""

  # User
  if pg_user_exists "$sanitized"; then
    echo "User '$sanitized': exists"
  else
    echo "User '$sanitized': MISSING"
  fi
  echo ""

  # Databases
  for prefix in "${DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    if pg_db_exists "$dbname"; then
      local size extensions tables
      size=$(pg_exec "SELECT pg_size_pretty(pg_database_size('$dbname'));")
      extensions=$(pg_exec_db "$dbname" "SELECT string_agg(extname || ' ' || extversion, ', ' ORDER BY extname) FROM pg_extension WHERE extname != 'plpgsql';")
      tables=$(pg_exec_db "$dbname" "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
      echo "Database '$dbname':"
      echo "  Size:       $size"
      echo "  Tables:     $tables"
      echo "  Extensions: ${extensions:-none}"
    else
      echo "Database '$dbname': MISSING"
    fi
  done
}

# --------------------------------------------------------------------------
# Backup / Restore
# --------------------------------------------------------------------------

PG_BACKUP_DIR="${HOME}/.local/share/wt-backups"

pg_backup_worktree_dbs() {
  local branch="$1"
  local backup_label="${2:-}"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_subdir="${PG_BACKUP_DIR}/${sanitized}/${timestamp}"

  mkdir -p "$backup_subdir"

  echo "==> Backing up databases for '$branch' (sanitized: '$sanitized')"

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

  if [[ -n "$backup_label" ]]; then
    echo "$backup_label" > "${backup_subdir}/label"
  fi

  echo "==> Backup saved to $backup_subdir"
}

pg_restore_worktree_dbs() {
  local branch="$1"
  local backup_subdir="$2"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")

  echo "==> Restoring databases for '$branch' from $backup_subdir"

  pg_create_user "$sanitized"

  for prefix in "${DB_PREFIXES[@]}"; do
    local dbname="${prefix}_${sanitized}"
    local dump_file="${backup_subdir}/${dbname}.dump"
    if [[ ! -f "$dump_file" ]]; then
      echo "No dump file for '$dbname', skipping."
      continue
    fi

    # Drop and recreate the database
    if pg_db_exists "$dbname"; then
      echo "Terminating connections to '$dbname'..."
      pg_exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$dbname' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true
      echo "Dropping '$dbname'..."
      pg_exec "DROP DATABASE \"$dbname\";"
    fi

    echo "Creating '$dbname'..."
    pg_exec "CREATE DATABASE \"$dbname\" OWNER \"$sanitized\";"

    echo "Restoring '$dbname' from $dump_file"
    PGPASSWORD="$PG_SUPERUSER" pg_restore \
      -U "$PG_SUPERUSER" -h localhost -p "$PG_PORT" \
      --no-owner --no-acl \
      -d "$dbname" "$dump_file"
  done

  echo "==> Done."
}

pg_list_backups() {
  local branch="$1"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")
  local backup_dir="${PG_BACKUP_DIR}/${sanitized}"

  if [[ ! -d "$backup_dir" ]]; then
    return 1
  fi

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
    echo "${ts}${label} —${sizes}"
  done
}

# Update POSTGRES_* vars in a .env file.
# Preserves all other lines. If no .env exists, creates one from the env vars alone.
pg_apply_env() {
  local env_file="$1"
  local branch="$2"
  local env_vars
  env_vars=$(pg_generate_env_urls "$branch")

  if [[ -f "$env_file" ]]; then
    local tmp
    tmp=$(mktemp)
    grep -v '^POSTGRES_' "$env_file" > "$tmp" || true
    # Remove trailing blank lines
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
    echo "" >> "$tmp"
    echo "$env_vars" >> "$tmp"
    mv "$tmp" "$env_file"
  else
    mkdir -p "$(dirname "$env_file")"
    echo "$env_vars" > "$env_file"
  fi
}

pg_generate_env_urls() {
  local branch="$1"
  local sanitized
  sanitized=$(pg_sanitize_branch_name "$branch")
  local user="$sanitized"

  cat <<EOF
POSTGRES_URL="postgresql://${user}:${user}@localhost:${PG_PORT}/platform_${sanitized}"
POSTGRES_PRISMA_URL="postgresql://${user}:${user}@localhost:${PG_PORT}/platform_${sanitized}?pgbouncer=true&connect_timeout=15"
POSTGRES_URL_NON_POOLING="postgresql://${user}:${user}@localhost:${PG_PORT}/platform_${sanitized}"
POSTGRES_USER="${user}"
POSTGRES_HOST="postgresql://${user}:${user}@localhost:${PG_PORT}"
POSTGRES_PASSWORD="${user}"
POSTGRES_DATABASE="platform_${sanitized}"

POSTGRES_VECTOR_URL="postgresql://${user}:${user}@localhost:${PG_PORT}/vector_${sanitized}"
POSTGRES_VECTOR_PRISMA_URL="postgresql://${user}:${user}@localhost:${PG_PORT}/vector_${sanitized}?pgbouncer=true&connect_timeout=15&pool_timeout=30&connection_limit=100"
POSTGRES_VECTOR_URL_NON_POOLING="postgresql://${user}:${user}@localhost:${PG_PORT}/vector_${sanitized}"
POSTGRES_VECTOR_USER="${user}"
POSTGRES_VECTOR_HOST="postgresql://${user}:${user}@localhost:${PG_PORT}"
POSTGRES_VECTOR_PASSWORD="${user}"
POSTGRES_VECTOR_DATABASE="vector_${sanitized}"
EOF
}
