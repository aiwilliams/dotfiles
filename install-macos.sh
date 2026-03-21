#!/usr/bin/env bash
set -euo pipefail

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

brew install tmux gh fzf shellcheck yq gitleaks mkcert caddy
brew install --cask ngrok

# --- Docker via Colima ---

echo "Installing Colima + Docker CLI..."
brew install colima docker docker-compose
if ! colima status &>/dev/null 2>&1; then
  colima start
fi

# --- PostgreSQL 18 + pgvector via Homebrew ---

echo "Installing PostgreSQL 18 + pgvector..."

brew install postgresql@18 pgvector
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/postgres.sh"
pg_create_worktree_dbs "main"
