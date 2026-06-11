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

# --- Docker resource limits ---

# Cap total Docker container memory to prevent containers from consuming all system RAM.
DOCKER_SLICE="/etc/systemd/system/docker-containers.slice"
if [ ! -f "$DOCKER_SLICE" ]; then
  echo "Creating Docker container memory limit slice (40G soft / 45G hard)..."
  cat <<'UNIT' | sudo tee "$DOCKER_SLICE" > /dev/null
[Unit]
Description=Limit total Docker container memory
Before=slices.target

[Slice]
MemoryHigh=40G
MemoryMax=45G
UNIT
  sudo systemctl daemon-reload
fi

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_DAEMON_JSON" ]; then
  echo "Configuring Docker daemon (cgroup parent, log rotation)..."
  cat <<'JSON' | sudo tee "$DOCKER_DAEMON_JSON" > /dev/null
{
  "cgroup-parent": "docker-containers.slice",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
JSON
  sudo systemctl restart docker
elif ! grep -q 'cgroup-parent' "$DOCKER_DAEMON_JSON"; then
  echo "WARNING: $DOCKER_DAEMON_JSON exists but missing cgroup-parent. Add manually:"
  echo '  "cgroup-parent": "docker-containers.slice"'
fi

# Cap Airbyte's k3s container to 32GB so JVMs using -XX:MaxRAMPercentage see
# a realistic limit instead of the full host RAM. Pods must restart to pick up
# the new cgroup limit (abctl local install --values handles this).
if docker inspect airbyte-abctl-control-plane &>/dev/null; then
  CURRENT_MEM=$(docker inspect airbyte-abctl-control-plane --format '{{.HostConfig.Memory}}')
  TARGET_MEM=$((32 * 1024 * 1024 * 1024))  # 32G in bytes
  if [ "$CURRENT_MEM" != "$TARGET_MEM" ]; then
    echo "Setting Airbyte container memory limit to 32G..."
    docker update --memory 32g --memory-swap 36g airbyte-abctl-control-plane
  fi
fi

# --- Locale ---

if ! locale -a 2>/dev/null | grep -qi 'en_US\.utf'; then
  echo "Generating en_US.UTF-8 locale..."
  sudo locale-gen en_US.UTF-8
fi
sudo update-locale LANG=en_US.UTF-8

# --- OOM protection (keep SSH/Tailscale alive under memory pressure) ---

# Protect tailscaled from BOTH out-of-memory killers. tailscaled is the lifeline
# — it serves Tailscale SSH, so if it dies the box is unreachable.
#   OOMScoreAdjust=-900     — tells the *kernel* OOM killer to spare it.
#   ManagedOOMPreference=omit — tells *systemd-oomd* to never pick it. oomd
#     ignores OOMScoreAdjust entirely; this xattr is the only lever it honours.
#     tailscaled lives in system.slice, which oomd does not currently monitor,
#     so this is belt-and-suspenders — it stays protected even if oomd is later
#     pointed at system.slice or the root cgroup.
TAILSCALED_OVERRIDE="/etc/systemd/system/tailscaled.service.d/oom-protect.conf"
TAILSCALED_OVERRIDE_DESIRED="[Service]
OOMScoreAdjust=-900
ManagedOOMPreference=omit"
if [ ! -f "$TAILSCALED_OVERRIDE" ] || ! diff -q <(echo "$TAILSCALED_OVERRIDE_DESIRED") "$TAILSCALED_OVERRIDE" &>/dev/null; then
  echo "Protecting tailscaled from OOM killers..."
  sudo mkdir -p /etc/systemd/system/tailscaled.service.d
  echo "$TAILSCALED_OVERRIDE_DESIRED" | sudo tee "$TAILSCALED_OVERRIDE" > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart tailscaled
fi

# Protect sshd the same way (the fallback path when not reaching the box over
# Tailscale SSH).
SSHD_OVERRIDE="/etc/systemd/system/ssh.service.d/oom-protect.conf"
SSHD_OVERRIDE_DESIRED="[Service]
OOMScoreAdjust=-900
ManagedOOMPreference=omit"
if [ ! -f "$SSHD_OVERRIDE" ] || ! diff -q <(echo "$SSHD_OVERRIDE_DESIRED") "$SSHD_OVERRIDE" &>/dev/null; then
  echo "Protecting sshd from OOM killers..."
  sudo mkdir -p /etc/systemd/system/ssh.service.d
  echo "$SSHD_OVERRIDE_DESIRED" | sudo tee "$SSHD_OVERRIDE" > /dev/null
  sudo systemctl daemon-reload
fi

# Two-layer OOM defense:
#   1. systemd-oomd (primary): PSI-aware, only acts on sustained pressure (~20s),
#      kills the worst single user-session cgroup. Handles routine memory spikes
#      (overlapping type-check + lint + dev-server) gracefully.
#   2. earlyoom (catastrophe fallback): only fires when memory + swap are both
#      near-zero — basically a last-ditch panic button before the kernel OOM
#      killer. tailscaled and sshd have OOMScoreAdjust=-900 so the kernel
#      backstop won't take them either.

# Layer 1: systemd-oomd PSI-based monitoring.
# 80% sustained pressure for 20s before acting. The earlier 60% (and the
# distro's 50% on user@.service, see below) fired on transient swap-thrash
# spikes during ordinary builds while tens of GB of RAM were still available —
# a pressure stall is not the same as memory exhaustion. earlyoom + the kernel
# remain the real out-of-memory backstops.
OOMD_CONF="/etc/systemd/oomd.conf.d/00-tuning.conf"
OOMD_CONF_DESIRED="[OOM]
SwapUsedLimit=95%
DefaultMemoryPressureLimit=80%
DefaultMemoryPressureDurationSec=20s"
if [ ! -f "$OOMD_CONF" ] || ! diff -q <(echo "$OOMD_CONF_DESIRED") "$OOMD_CONF" &>/dev/null; then
  echo "Configuring systemd-oomd thresholds..."
  sudo mkdir -p /etc/systemd/oomd.conf.d
  echo "$OOMD_CONF_DESIRED" | sudo tee "$OOMD_CONF" > /dev/null
fi

# Override the distro default that hard-sets ManagedOOMMemoryPressureLimit=50%
# on every user@.service (/usr/lib/systemd/system/user@.service.d/
# 10-oomd-user-service-defaults.conf). That per-unit limit shadows
# DefaultMemoryPressureLimit above, so without this drop-in oomd still kills the
# heaviest-reclaim scope under the login session at 50% — the cause of the
# claude-session kills. 99- sorts after the distro's 10- so it wins.
USER_SERVICE_OOMD="/etc/systemd/system/user@.service.d/99-oomd-pressure.conf"
USER_SERVICE_OOMD_DESIRED="[Service]
ManagedOOMMemoryPressureLimit=80%"
if [ ! -f "$USER_SERVICE_OOMD" ] || ! diff -q <(echo "$USER_SERVICE_OOMD_DESIRED") "$USER_SERVICE_OOMD" &>/dev/null; then
  echo "Raising user@.service oomd pressure limit to 80%..."
  sudo mkdir -p /etc/systemd/system/user@.service.d
  echo "$USER_SERVICE_OOMD_DESIRED" | sudo tee "$USER_SERVICE_OOMD" > /dev/null
  sudo systemctl daemon-reload
fi

# Opt user.slice into oomd management. Without this, oomd does nothing — the
# default ManagedOOM* settings on user.slice are "auto" which is effectively off.
USER_SLICE_OOMD="/etc/systemd/system/user.slice.d/00-oomd.conf"
USER_SLICE_OOMD_DESIRED="[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMSwap=kill"
if [ ! -f "$USER_SLICE_OOMD" ] || ! diff -q <(echo "$USER_SLICE_OOMD_DESIRED") "$USER_SLICE_OOMD" &>/dev/null; then
  echo "Enabling oomd management on user.slice..."
  sudo mkdir -p /etc/systemd/system/user.slice.d
  echo "$USER_SLICE_OOMD_DESIRED" | sudo tee "$USER_SLICE_OOMD" > /dev/null
  sudo systemctl daemon-reload
fi

sudo systemctl enable systemd-oomd
sudo systemctl restart systemd-oomd

# Layer 2: earlyoom as catastrophic fallback.
if ! command -v earlyoom &>/dev/null; then
  echo "Installing earlyoom..."
  sudo apt-get install -y earlyoom
fi

# Thresholds are intentionally close to kernel-OOM levels — oomd handles routine
# pressure first via PSI (with a 20s sustained-pressure window). earlyoom only
# fires when memory available drops below 3% AND swap free drops below 5%, with
# SIGKILL at 1%/2%. Above that, the kernel OOM killer is the absolute backstop.
# --avoid: kill these only as a last resort (subtracts 300 from oom_score).
#   Killing the postgres parent or the JetBrains Remote Dev backend ("idea")
#   takes down the whole DB / IDE session, so they're protected but still killable
#   if it's the only way to keep tailscaled+sshd alive. "claude" (Claude Code,
#   comm=claude) is protected the same way — it is itself a node process, so
#   without this guard --prefer would target long-running interactive sessions
#   first; runaway build/dev node processes stay in --prefer and die before it.
EARLYOOM_CONF="/etc/default/earlyoom"
EARLYOOM_DESIRED="EARLYOOM_ARGS=\"-m 3,1 -s 5,2 -r 3600 --avoid '^(tailscaled|sshd|systemd|containerd|dockerd|postgres|idea|claude)\$' --prefer '^(next-server|node|tsgo|chrome|firefox)\$' -n\""
if [ ! -f "$EARLYOOM_CONF" ] || ! diff -q <(echo "$EARLYOOM_DESIRED") "$EARLYOOM_CONF" &>/dev/null; then
  echo "Configuring earlyoom..."
  echo "$EARLYOOM_DESIRED" | sudo tee "$EARLYOOM_CONF" > /dev/null
fi

# Let earlyoom see all processes in /proc. The upstream unit uses DynamicUser=true
# which prevents it from reading other users' entries under /proc.
EARLYOOM_OVERRIDE="/etc/systemd/system/earlyoom.service.d/proc-access.conf"
EARLYOOM_OVERRIDE_DESIRED="[Service]
DynamicUser=false
User=root"
if [ ! -f "$EARLYOOM_OVERRIDE" ] || ! grep -q 'DynamicUser=false' "$EARLYOOM_OVERRIDE"; then
  echo "Configuring earlyoom proc access..."
  sudo mkdir -p /etc/systemd/system/earlyoom.service.d
  echo "$EARLYOOM_OVERRIDE_DESIRED" | sudo tee "$EARLYOOM_OVERRIDE" > /dev/null
  sudo systemctl daemon-reload
fi

sudo systemctl enable earlyoom
sudo systemctl restart earlyoom

# --- Kernel tuning ---

SYSCTL_INOTIFY="/etc/sysctl.d/60-inotify.conf"
if [ ! -f "$SYSCTL_INOTIFY" ]; then
  echo "Increasing inotify watch limit..."
  echo "fs.inotify.max_user_watches=524288" | sudo tee "$SYSCTL_INOTIFY" > /dev/null
  sudo sysctl --system
fi

SYSCTL_DELAYACCT="/etc/sysctl.d/60-delayacct.conf"
if [ ! -f "$SYSCTL_DELAYACCT" ]; then
  echo "Enabling delay accounting for ClickHouse OSIOWaitMicroseconds..."
  echo "kernel.task_delayacct=1" | sudo tee "$SYSCTL_DELAYACCT" > /dev/null
  sudo sysctl --system
fi

SYSCTL_MEMORY="/etc/sysctl.d/60-memory.conf"
TOTAL_RAM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
# Reserve ~1% of RAM for min_free_kbytes, clamped to 128MB–1GB
MIN_FREE_KB=$(( TOTAL_RAM_KB / 100 ))
(( MIN_FREE_KB < 131072 )) && MIN_FREE_KB=131072
(( MIN_FREE_KB > 1048576 )) && MIN_FREE_KB=1048576
# Less RAM → more willing to swap; plenty of RAM → strongly prefer RAM
if (( TOTAL_RAM_KB <= 8388608 )); then
  SWAPPINESS=30
elif (( TOTAL_RAM_KB <= 33554432 )); then
  SWAPPINESS=15
else
  SWAPPINESS=10
fi
SYSCTL_MEMORY_DESIRED="vm.min_free_kbytes=$MIN_FREE_KB
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=50"
if [ ! -f "$SYSCTL_MEMORY" ] || ! diff -q <(echo "$SYSCTL_MEMORY_DESIRED") "$SYSCTL_MEMORY" &>/dev/null; then
  echo "Configuring kernel memory tuning (min_free_kbytes=${MIN_FREE_KB}kB, swappiness=$SWAPPINESS, vfs_cache_pressure=50)..."
  echo "$SYSCTL_MEMORY_DESIRED" | sudo tee "$SYSCTL_MEMORY" > /dev/null
  sudo sysctl --system
fi

# --- Network resilience (keep machine accessible remotely) ---

# Make NetworkManager retry DHCP forever instead of giving up after 4 attempts
WIRED_CONN=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-3-ethernet$' | head -1 | cut -d: -f1)
if [ -n "$WIRED_CONN" ]; then
  CURRENT_RETRIES=$(nmcli -t -f connection.autoconnect-retries connection show "$WIRED_CONN" 2>/dev/null | cut -d: -f2)
  if [ "$CURRENT_RETRIES" != "0" ]; then
    echo "Configuring DHCP to retry forever on $WIRED_CONN..."
    sudo nmcli connection modify "$WIRED_CONN" \
      connection.autoconnect-retries 0 \
      ipv4.dhcp-timeout 2147483647
  fi
fi

# Network watchdog: check gateway reachability, restart NetworkManager if down
WATCHDOG_SCRIPT="/usr/local/bin/network-watchdog.sh"
cat <<'SCRIPT' | sudo tee "$WATCHDOG_SCRIPT" > /dev/null
#!/usr/bin/env bash
set -euo pipefail

GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')

if [ -z "$GATEWAY" ]; then
  logger -t network-watchdog "No default gateway, restarting NetworkManager"
  systemctl restart NetworkManager
  exit 0
fi

if ! ping -c 3 -W 5 "$GATEWAY" &>/dev/null; then
  logger -t network-watchdog "Gateway $GATEWAY unreachable, restarting NetworkManager"
  systemctl restart NetworkManager
fi
SCRIPT
sudo chmod 755 "$WATCHDOG_SCRIPT"

WATCHDOG_SERVICE="/etc/systemd/system/network-watchdog.service"
if [ ! -f "$WATCHDOG_SERVICE" ]; then
  echo "Installing network watchdog timer..."
  cat <<'UNIT' | sudo tee "$WATCHDOG_SERVICE" > /dev/null
[Unit]
Description=Network connectivity watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/network-watchdog.sh
UNIT

  cat <<'UNIT' | sudo tee /etc/systemd/system/network-watchdog.timer > /dev/null
[Unit]
Description=Run network watchdog every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now network-watchdog.timer
fi

# Restart Tailscale promptly when the physical network interface recovers
TAILSCALE_DISPATCHER="/etc/NetworkManager/dispatcher.d/99-restart-tailscale"
if [ ! -f "$TAILSCALE_DISPATCHER" ]; then
  echo "Installing Tailscale network recovery dispatcher..."
  cat <<'DISPATCH' | sudo tee "$TAILSCALE_DISPATCHER" > /dev/null
#!/bin/bash
INTERFACE=$1
ACTION=$2

# Ignore virtual interfaces
case "$INTERFACE" in
  lo|docker*|br-*|veth*|tailscale*) exit 0 ;;
esac

if [ "$ACTION" = "up" ]; then
  logger -t nm-dispatcher "Interface $INTERFACE came up, restarting tailscaled"
  systemctl restart tailscaled
fi
DISPATCH
  sudo chmod 755 "$TAILSCALE_DISPATCHER"
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

# --- ClickHouse (single binary, same approach as macOS) ---

echo "Installing ClickHouse..."

source "$SCRIPT_DIR/lib/clickhouse.sh"
ch_install_binary

# Install systemd user service for auto-start (equivalent of macOS launchd plist)
CH_SERVICE_DIR="$HOME/.config/systemd/user"
CH_SERVICE="$CH_SERVICE_DIR/clickhouse-server.service"
mkdir -p "$CH_SERVICE_DIR"

cat > "$CH_SERVICE" <<UNIT
[Unit]
Description=ClickHouse Server (user)
After=network.target

[Service]
Type=simple
ExecStart=${CH_BIN} server -- --path=${CH_DATA}/
WorkingDirectory=${CH_DATA}
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable clickhouse-server
systemctl --user start clickhouse-server

# Ensure user services start at boot (even without login session)
sudo loginctl enable-linger "$USER" 2>/dev/null || true

ch_wait_for_start || echo "Check: journalctl --user -u clickhouse-server"

# --- mkcert ---

if ! command -v mkcert &>/dev/null; then
  echo "Installing mkcert..."
  sudo apt-get install -y libnss3-tools
  curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /tmp/mkcert
  sudo install -m 755 /tmp/mkcert /usr/local/bin/mkcert
  rm -f /tmp/mkcert
fi

# --- Caddy ---

if ! command -v caddy &>/dev/null; then
  echo "Installing Caddy..."
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y caddy
  # Stop the default systemd service — we manage Caddy ourselves via opine-proxy
  sudo systemctl stop caddy 2>/dev/null || true
  sudo systemctl disable caddy 2>/dev/null || true
fi

# --- ngrok ---

if ! command -v ngrok &>/dev/null; then
  echo "Installing ngrok..."
  curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
    | sudo tee /etc/apt/keyrings/ngrok.asc > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com buster main" \
    | sudo tee /etc/apt/sources.list.d/ngrok.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y ngrok
fi

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
