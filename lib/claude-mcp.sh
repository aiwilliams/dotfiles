#!/usr/bin/env bash
# claude-mcp.sh — Configure Claude Code MCP servers (user-scoped).

set -euo pipefail

if ! command -v claude &>/dev/null; then
  echo "Error: claude is required. Install Claude Code first." >&2
  return 1
fi

echo "Configuring Claude Code MCP servers..."

# Headless browser automation
claude mcp add --transport stdio playwright -- npx -y @modelcontextprotocol/server-playwright

# Up-to-date library documentation
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  claude mcp add --transport stdio context7 -- npx -y @upstash/context7-mcp --api-key "$CONTEXT7_API_KEY"
else
  echo "Skipping Context7 MCP: set CONTEXT7_API_KEY to enable."
fi

echo "Claude Code MCP servers configured."
