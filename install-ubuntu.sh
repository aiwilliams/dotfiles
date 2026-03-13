#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running Ubuntu setup..."

# --- System packages ---

sudo apt-get update -y
sudo apt-get install -y zsh tmux keychain build-essential python3 curl ca-certificates fzf shellcheck docker.io docker-compose-v2

# --- Docker ---

sudo systemctl enable docker
sudo systemctl start docker
if ! groups "$USER" | grep -q '\bdocker\b'; then
  echo "Adding $USER to docker group..."
  sudo usermod -aG docker "$USER"
  echo "NOTE: Log out and back in (or run 'newgrp docker') for group change to take effect."
fi

# --- Locale ---

if ! locale -a 2>/dev/null | grep -qi 'en_US\.utf'; then
  echo "Generating en_US.UTF-8 locale..."
  sudo locale-gen en_US.UTF-8
fi
sudo update-locale LANG=en_US.UTF-8

# --- OOM protection (keep SSH/Tailscale alive under memory pressure) ---

# Protect tailscaled from OOM killer
TAILSCALED_OVERRIDE="/etc/systemd/system/tailscaled.service.d/oom-protect.conf"
if [ ! -f "$TAILSCALED_OVERRIDE" ]; then
  echo "Protecting tailscaled from OOM killer..."
  sudo mkdir -p /etc/systemd/system/tailscaled.service.d
  cat <<'UNIT' | sudo tee "$TAILSCALED_OVERRIDE" > /dev/null
[Service]
OOMScoreAdjust=-900
UNIT
  sudo systemctl daemon-reload
  sudo systemctl restart tailscaled
fi

# Install earlyoom to kill memory hogs before the system becomes unresponsive
if ! command -v earlyoom &>/dev/null; then
  echo "Installing earlyoom..."
  sudo apt-get install -y earlyoom
fi

EARLYOOM_CONF="/etc/default/earlyoom"
EARLYOOM_DESIRED="EARLYOOM_ARGS=\"-m 5 -s 10 --avoid '(^|/)(tailscaled|sshd|systemd|containerd|dockerd)\$' --prefer '(^|/)(next-server|node|chrome|firefox)\$' -n\""
if ! grep -qF -- '--avoid' "$EARLYOOM_CONF" 2>/dev/null; then
  echo "Configuring earlyoom..."
  echo "$EARLYOOM_DESIRED" | sudo tee "$EARLYOOM_CONF" > /dev/null
  sudo systemctl enable earlyoom
  sudo systemctl restart earlyoom
fi

# --- Kernel tuning ---

SYSCTL_INOTIFY="/etc/sysctl.d/60-inotify.conf"
if [ ! -f "$SYSCTL_INOTIFY" ]; then
  echo "Increasing inotify watch limit..."
  echo "fs.inotify.max_user_watches=524288" | sudo tee "$SYSCTL_INOTIFY" > /dev/null
  sudo sysctl --system
fi

# --- GitHub CLI ---

if ! command -v gh &>/dev/null; then
  echo "Installing GitHub CLI..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y gh
fi

# --- PostgreSQL 18 + pgvector ---

# Add PGDG repo only if not already configured
if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
  echo "Adding PostgreSQL apt repository..."
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
  sudo apt-get update -y
fi

echo "Installing PostgreSQL 18 + pgvector..."
sudo apt-get install -y postgresql-18 postgresql-18-pgvector

sudo systemctl enable postgresql
sudo systemctl start postgresql

PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;")
PG_CONF=$(sudo -u postgres psql -tAc "SHOW config_file;")
DOCKER_BRIDGE="172.17.0.1"
DOCKER_SUBNET="172.17.0.0/16"
PG_NEEDS_RESTART="false"

# Set postgres superuser password (via peer auth, which works before we change pg_hba)
# Uses a no-op comparison to avoid ALTER on every run
CURRENT_AUTH=$(sudo -u postgres psql -tAc "SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'postgres';" 2>/dev/null || echo "")
if [[ "$CURRENT_AUTH" != "t" ]]; then
  echo "Setting postgres superuser password..."
  sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"
fi

# Configure pg_hba.conf to use password auth for local TCP connections
if sudo grep -qE '^\s*(local|host)\s+all\s+all\s.*(peer|ident|scram-sha-256)' "$PG_HBA"; then
  echo "Configuring pg_hba.conf for md5 auth..."
  sudo sed -i 's/^\(local\s\+all\s\+all\s\+\)peer/\1md5/' "$PG_HBA"
  sudo sed -i 's/^\(host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\)ident/\1md5/' "$PG_HBA"
  sudo sed -i 's/^\(host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\)scram-sha-256/\1md5/' "$PG_HBA"
  sudo sed -i 's/^\(host\s\+all\s\+all\s\+::1\/128\s\+\)ident/\1md5/' "$PG_HBA"
  sudo sed -i 's/^\(host\s\+all\s\+all\s\+::1\/128\s\+\)scram-sha-256/\1md5/' "$PG_HBA"
  PG_NEEDS_RESTART="true"
fi

# Allow Docker containers to connect to PostgreSQL
# 1. Add Docker bridge IP to listen_addresses in postgresql.conf
CURRENT_LISTEN=$(sudo grep -E "^listen_addresses\s*=" "$PG_CONF" 2>/dev/null || true)
if [[ -z "$CURRENT_LISTEN" ]]; then
  echo "listen_addresses = 'localhost,$DOCKER_BRIDGE'" | sudo tee -a "$PG_CONF" > /dev/null
  PG_NEEDS_RESTART="true"
elif ! echo "$CURRENT_LISTEN" | grep -qF "$DOCKER_BRIDGE"; then
  sudo sed -i "s/^\(listen_addresses\s*=\s*'\)\([^']*\)'/\1\2,$DOCKER_BRIDGE'/" "$PG_CONF"
  PG_NEEDS_RESTART="true"
fi

# 2. Add pg_hba rule for Docker subnet (idempotent — skip if already present)
if ! sudo grep -qE "^host\s+all\s+all\s+${DOCKER_SUBNET//\//\\/}\s" "$PG_HBA"; then
  echo "host    all             all             $DOCKER_SUBNET            md5" | sudo tee -a "$PG_HBA" > /dev/null
  PG_NEEDS_RESTART="true"
fi

# Increase max_connections for concurrent test suites (default 100 is too low)
CURRENT_MAX_CONN=$(sudo grep -E "^max_connections\s*=" "$PG_CONF" 2>/dev/null || true)
if [[ -z "$CURRENT_MAX_CONN" ]]; then
  echo "max_connections = 300" | sudo tee -a "$PG_CONF" > /dev/null
  PG_NEEDS_RESTART="true"
elif [[ "$CURRENT_MAX_CONN" != *"300"* ]]; then
  sudo sed -i "s/^max_connections\s*=.*/max_connections = 300/" "$PG_CONF"
  PG_NEEDS_RESTART="true"
fi

# Only restart if config actually changed
if [[ "$PG_NEEDS_RESTART" == "true" ]]; then
  echo "PostgreSQL config changed, restarting..."
  sudo systemctl restart postgresql
fi

# Create main worktree databases (no sudo needed from here)
source "$SCRIPT_DIR/lib/postgres.sh"
pg_create_worktree_dbs "main"

# --- gitleaks ---

if ! command -v gitleaks &>/dev/null; then
  echo "Installing gitleaks..."
  GITLEAKS_VERSION="8.30.0"
  curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | sudo tar -xz -C /usr/local/bin gitleaks
fi

# --- zmx ---

if ! command -v zmx &>/dev/null; then
  echo "Installing zmx..."
  ZMX_VERSION="0.4.1"
  ZMX_ARCH="$(uname -m)"
  curl -fLo /tmp/zmx.tar.gz "https://zmx.sh/a/zmx-${ZMX_VERSION}-linux-${ZMX_ARCH}.tar.gz"
  tar -xzf /tmp/zmx.tar.gz -C /tmp
  sudo install -m 755 /tmp/zmx /usr/local/bin/zmx
  rm -f /tmp/zmx /tmp/zmx.tar.gz
fi

# --- Shell config ---

KEYCHAIN_LINE='eval "$(keychain --eval --agents ssh id_ed25519_$(hostname))"'
if ! grep -qF "keychain --eval" "$HOME/.bashrc"; then
  echo "" >> "$HOME/.bashrc"
  echo "# Load SSH key via keychain" >> "$HOME/.bashrc"
  echo "$KEYCHAIN_LINE" >> "$HOME/.bashrc"
  echo "Added keychain to ~/.bashrc"
fi
