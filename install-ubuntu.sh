#!/usr/bin/env bash
set -euo pipefail

echo "Running Ubuntu setup..."

sudo apt-get update -y
sudo apt-get install -y tmux keychain build-essential python3 curl ca-certificates

# --- PostgreSQL 18 + pgvector via PGDG apt repo ---

echo "Installing PostgreSQL 18 + pgvector..."

sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y postgresql-18 postgresql-18-pgvector

sudo systemctl enable postgresql
sudo systemctl start postgresql

# Set postgres superuser password (via peer auth, which works before we change pg_hba)
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"

# Configure pg_hba.conf to use password auth for local TCP connections
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;")
# Replace peer/ident with md5 for local and host entries
sudo sed -i 's/^\(local\s\+all\s\+all\s\+\)peer/\1md5/' "$PG_HBA"
sudo sed -i 's/^\(host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\)ident/\1md5/' "$PG_HBA"
sudo sed -i 's/^\(host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\)scram-sha-256/\1md5/' "$PG_HBA"
sudo sed -i 's/^\(host\s\+all\s\+all\s\+::1\/128\s\+\)ident/\1md5/' "$PG_HBA"
sudo sed -i 's/^\(host\s\+all\s\+all\s\+::1\/128\s\+\)scram-sha-256/\1md5/' "$PG_HBA"
sudo systemctl reload postgresql

# Create main worktree databases (no sudo needed from here)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/postgres.sh"
pg_create_worktree_dbs "main"

# Install mise
if ! command -v mise &>/dev/null; then
  curl https://mise.run | sh
  echo 'eval "$(~/.local/bin/mise activate bash)"' >> "$HOME/.bashrc"
  echo "Installed mise and added to ~/.bashrc"
fi

KEYCHAIN_LINE='eval "$(keychain --eval --agents ssh id_ed25519_$(hostname))"'
if ! grep -qF "keychain --eval" "$HOME/.bashrc"; then
  echo "" >> "$HOME/.bashrc"
  echo "# Load SSH key via keychain" >> "$HOME/.bashrc"
  echo "$KEYCHAIN_LINE" >> "$HOME/.bashrc"
  echo "Added keychain to ~/.bashrc"
fi
