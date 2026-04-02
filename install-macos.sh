#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/brew.sh"

echo "Running macOS setup..."

# --- Homebrew ---

if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  echo "Updating Homebrew..."
  brew update
fi

brew_install tmux gh fzf shellcheck yq gitleaks mkcert caddy util-linux
brew_install_cask ngrok

# --- Docker via Colima ---

echo "Installing Colima + Docker CLI..."
brew_install colima docker docker-compose
if ! colima status &>/dev/null 2>&1; then
  colima start
fi

# --- PostgreSQL 18 + pgvector via Homebrew ---

echo "Installing PostgreSQL 18 + pgvector..."

brew_install postgresql@18 pgvector
brew services start postgresql@18

echo "Waiting for PostgreSQL to start..."
for _ in {1..30}; do
  if pg_isready -p 5432 > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Set postgres superuser password
psql -U postgres -c "ALTER USER postgres PASSWORD 'postgres';" 2>/dev/null || \
  createuser -s postgres 2>/dev/null && \
  psql -U postgres -c "ALTER USER postgres PASSWORD 'postgres';"

# Create main worktree databases
source "$SCRIPT_DIR/lib/postgres.sh"
pg_create_worktree_dbs "main"

# --- ClickHouse via curl (Homebrew package is deprecated) ---

echo "Installing ClickHouse..."

CH_BIN="$HOME/.local/bin/clickhouse"
CH_DATA="$HOME/.local/share/clickhouse"
CH_PLIST_LABEL="com.clickhouse.server"
CH_PLIST="$HOME/Library/LaunchAgents/${CH_PLIST_LABEL}.plist"

mkdir -p "$HOME/.local/bin" "$CH_DATA"

if [[ -f "$CH_BIN" ]]; then
  echo "ClickHouse already installed at $CH_BIN, skipping download."
else
  echo "Downloading ClickHouse binary..."
  tmpdir=$(mktemp -d)
  (cd "$tmpdir" && curl -fsSL https://clickhouse.com/ | sh)
  mv "$tmpdir/clickhouse" "$CH_BIN"
  chmod +x "$CH_BIN"
  rm -rf "$tmpdir"
  # Remove macOS quarantine flag to avoid Gatekeeper prompt
  xattr -d com.apple.quarantine "$CH_BIN" 2>/dev/null || true
fi

# Install launchd plist for auto-start
cat > "$CH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CH_PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CH_BIN}</string>
        <string>server</string>
        <string>--</string>
        <string>--path=${CH_DATA}/</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${CH_DATA}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CH_DATA}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${CH_DATA}/stderr.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${CH_PLIST_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$CH_PLIST"

echo "Waiting for ClickHouse to start..."
for _ in {1..30}; do
  if clickhouse client --host localhost --port 9000 -q "SELECT 1" &>/dev/null; then
    break
  fi
  sleep 1
done

if clickhouse client --host localhost --port 9000 -q "SELECT 1" &>/dev/null; then
  echo "ClickHouse is running on ports 9000 (TCP) / 8123 (HTTP)."
else
  echo "Warning: ClickHouse did not start within 30s. Check $CH_DATA/stderr.log"
fi
