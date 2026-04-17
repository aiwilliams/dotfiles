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

# --- ClickHouse (single binary, Homebrew package is deprecated) ---

echo "Installing ClickHouse..."

source "$SCRIPT_DIR/lib/clickhouse.sh"
ch_install_binary

# Install launchd plist for auto-start
CH_PLIST_LABEL="com.clickhouse.server"
CH_PLIST="$HOME/Library/LaunchAgents/${CH_PLIST_LABEL}.plist"

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

if launchctl print "gui/$(id -u)/${CH_PLIST_LABEL}" &>/dev/null; then
  launchctl kickstart -k "gui/$(id -u)/${CH_PLIST_LABEL}"
else
  launchctl bootstrap "gui/$(id -u)" "$CH_PLIST"
fi

ch_wait_for_start || echo "Check $CH_DATA/stderr.log"
