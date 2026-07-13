#!/usr/bin/env bash
# claude-mcp.sh — Configure Claude Code MCP servers (user-scoped).

set -euo pipefail

if ! command -v claude &>/dev/null; then
  echo "Error: claude is required. Install Claude Code first." >&2
  return 1
fi

echo "Configuring Claude Code MCP servers..."

# Add an MCP server only if it isn't already configured. `claude mcp add` exits
# non-zero when the server already exists, which under `set -e` would abort the
# whole install; guarding on `claude mcp get` keeps re-runs idempotent.
mcp_add() {
  local name="$1"; shift
  if claude mcp get "$name" &>/dev/null; then
    echo "MCP server $name already configured, skipping."
    return 0
  fi
  claude mcp add "$@"
}

# Headless browser automation
mcp_add playwright --transport stdio playwright -- npx -y @modelcontextprotocol/server-playwright

# Up-to-date library documentation
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  mcp_add context7 --transport stdio context7 -- npx -y @upstash/context7-mcp --api-key "$CONTEXT7_API_KEY"
else
  echo "Skipping Context7 MCP: set CONTEXT7_API_KEY to enable."
fi

# Database access via dbhub (config file managed by wt agent-env)
mcp_add dbhub --scope user --transport stdio dbhub -- pnpm dlx @bytebase/dbhub --transport stdio --config "$HOME/projects/private/dbhub.private.toml"

# ClickHouse — one user-scoped server that adapts per worktree. The per-worktree
# database (and any host overrides) arrive via mise-injected .env.agent, which wt
# writes into each worktree; Claude expands ${CLICKHOUSE_*} from its environment
# when it launches the server. The :-defaults keep it working outside a worktree.
# Name comes first and the --env list is terminated by `--`: `claude mcp add`'s
# --env flag is variadic, so a name positional placed after it gets swallowed as
# a malformed env entry. (mcp_add repeats the name: once for the get-check, once
# as the add positional.)
mcp_add clickhouse clickhouse --scope user \
  --env 'CLICKHOUSE_HOST=${CLICKHOUSE_HOST:-localhost}' \
  --env 'CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-8123}' \
  --env 'CLICKHOUSE_USER=${CLICKHOUSE_USER:-default}' \
  --env 'CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD:-}' \
  --env 'CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-default}' \
  --env 'CLICKHOUSE_SECURE=${CLICKHOUSE_SECURE:-false}' \
  --env 'CLICKHOUSE_VERIFY=${CLICKHOUSE_VERIFY:-false}' \
  -- uvx mcp-clickhouse

echo "Claude Code MCP servers configured."
