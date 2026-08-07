#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running Ubuntu setup..."

# --- System packages ---

sudo apt-get update -y
sudo apt-get install -y zsh tmux keychain build-essential python3 curl ca-certificates fzf shellcheck docker.io docker-compose-v2

# --- Homebrew (Linux) ---
#
# Installed for one thing only: the Graphite CLI (gt), as a standalone prebuilt
# binary that's decoupled from any project's Node version (see lib/dev-tools.sh).
# Everything else on Linux stays on apt — do NOT migrate other packages to brew.
# Deps + prefix per https://docs.brew.sh/Homebrew-on-Linux. The installer must
# run as the normal user (it uses sudo itself); never run it as root.

if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ] && ! command -v brew &>/dev/null; then
  echo "Installing Homebrew (for Graphite CLI)..."
  sudo apt-get install -y procps file git
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

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
# Restart policy "no": Airbyte must not auto-start with the Docker daemon
# (its default on-failure policy resurrects it after every host crash/reboot).
# Start it manually with: docker start airbyte-abctl-control-plane
if docker inspect airbyte-abctl-control-plane &>/dev/null; then
  CURRENT_MEM=$(docker inspect airbyte-abctl-control-plane --format '{{.HostConfig.Memory}}')
  TARGET_MEM=$((32 * 1024 * 1024 * 1024))  # 32G in bytes
  if [ "$CURRENT_MEM" != "$TARGET_MEM" ]; then
    echo "Setting Airbyte container memory limit to 32G..."
    docker update --memory 32g --memory-swap 36g airbyte-abctl-control-plane
  fi
  CURRENT_RESTART=$(docker inspect airbyte-abctl-control-plane --format '{{.HostConfig.RestartPolicy.Name}}')
  if [ "$CURRENT_RESTART" != "no" ]; then
    echo "Disabling Airbyte container auto-restart..."
    docker update --restart=no airbyte-abctl-control-plane
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

# Two-layer OOM defense, split by kill granularity:
#   1. systemd-oomd (pressure only): PSI-aware, acts on sustained pressure
#      (~20s), kills the worst whole cgroup under user@.service. Handles
#      routine reclaim storms (overlapping type-check + lint + dev-server).
#      Deliberately NOT used for swap exhaustion — see the user.slice note
#      below: its swap path cannot be made to spare claude session scopes.
#   2. earlyoom + kernel OOM killer (memory/swap exhaustion): per-PROCESS
#      killers, so they take the fattest process (a test runner, a
#      next-server) rather than a whole session cgroup — an orchestrating
#      claude session survives its expendable children. earlyoom --avoid
#      spares claude/postgres/etc by name; tailscaled and sshd have
#      OOMScoreAdjust=-900 so the kernel backstop won't take them either.

# Layer 1: systemd-oomd PSI-based monitoring.
# 80% sustained pressure for 20s before acting. The earlier 60% (and the
# distro's 50% on user@.service, see below) fired on transient swap-thrash
# spikes during ordinary builds while tens of GB of RAM were still available —
# a pressure stall is not the same as memory exhaustion. earlyoom + the kernel
# remain the real out-of-memory backstops. (No SwapUsedLimit tuning: nothing
# sets ManagedOOMSwap=kill anymore, so oomd's swap killer is entirely off.)
OOMD_CONF="/etc/systemd/oomd.conf.d/00-tuning.conf"
OOMD_CONF_DESIRED="[OOM]
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

# user.slice is deliberately NOT opted into oomd management. An earlier
# revision set ManagedOOMMemoryPressure=kill + ManagedOOMSwap=kill here, but
# per systemd.resource-control(5) both monitors on the root-owned /user.slice
# ignore ManagedOOMPreference xattrs on user-owned cgroups: the swap path
# honors them ONLY on root-owned cgroups (no exceptions), and the pressure
# path only when the candidate's owner matches the monitored cgroup's owner.
# Result: claude scopes marked omit were killed anyway once they held the
# most swap (2026-07-17 00:57, scope-claude-1130049, 13.5G swapped).
#
# Pressure kills still work via the distro's ManagedOOMMemoryPressure=kill on
# user@.service (10-oomd-user-service-defaults.conf, limit raised to 80%
# above): each per-uid user@.service instance owns its cgroup with the same
# uid as its descendants, so omit IS honored on that path. Swap exhaustion is ceded to earlyoom + the
# kernel OOM killer, which kill per-process — the fat child dies, not the
# orchestrating session that spawned it.
USER_SLICE_OOMD="/etc/systemd/system/user.slice.d/00-oomd.conf"
if [ -f "$USER_SLICE_OOMD" ]; then
  echo "Removing oomd kill management from user.slice (swap kills ignore user-owned omit xattrs)..."
  sudo rm "$USER_SLICE_OOMD"
  sudo rmdir --ignore-fail-on-non-empty /etc/systemd/system/user.slice.d
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
# --prefer matches against /proc/PID/comm, NOT the cmdline, and the two biggest
#   consumers on this box do not present as plain "node":
#     vitest workers set comm to "node (vitest)"  (13-15G each)
#     the TypeScript 7 native compiler is comm "tsc", not "tsgo" (~10G)
#   Neither matched "^node$"/"^tsgo$", so earlyoom fell back to ranking them by
#   raw badness and the intent was never actually encoded. Verified with
#   `earlyoom --dryrun --debug`: both score 666 (no bonus) under the old regex
#   and 966 (+300, "<--- new victim") under this one.
#   The vitest alternative is written "node .vitest." with DOT WILDCARDS, not
#   escaped parens. systemd's EnvironmentFile parser unescapes backslashes
#   inside the double-quoted value, so a "\(" written here reaches earlyoom as
#   a bare "(" — an ERE capture group, which silently matches "node vitest"
#   (a process that does not exist) instead of the real "node (vitest)". The
#   quoting IS otherwise honored: systemd passes the regex as one argv entry
#   despite the embedded space. Verify any change against what earlyoom logs
#   at startup, NOT against a shell command line:
#     journalctl -u earlyoom -n20 | grep Preferring
EARLYOOM_CONF="/etc/default/earlyoom"
EARLYOOM_DESIRED="EARLYOOM_ARGS=\"-m 3,1 -s 5,2 -r 3600 --avoid '^(tailscaled|sshd|systemd|containerd|dockerd|postgres|idea|claude)\$' --prefer '^(next-server|node .vitest.|node|tsc|tsgo|chrome|firefox)\$' -n\""
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

# --- journald bounds ---
#
# journald.conf shipped empty, so everything ran on defaults: SystemMaxUse is
# then 10% of /var capped at 4G, which the box reached — 4.1G of journal
# holding barely two days, because ClickHouse was 99.4% of all entries. An
# explicit cap makes the ceiling intentional rather than incidental, and
# keeps journal growth off the same filesystem budget as everything else.
#
# The rate limit stays at its default here ON PURPOSE. Raising it globally
# would let one noisy unit evict more of everyone else's logs; the fix for a
# flooding unit is a per-unit LogRateLimitBurst on that unit (see
# clickhouse-server.service below), which confines the damage to itself.
JOURNALD_CONF="/etc/systemd/journald.conf.d/00-limits.conf"
JOURNALD_CONF_DESIRED="[Journal]
SystemMaxUse=1G
SystemKeepFree=2G
MaxRetentionSec=1week"
if [ ! -f "$JOURNALD_CONF" ] || ! diff -q <(echo "$JOURNALD_CONF_DESIRED") "$JOURNALD_CONF" &>/dev/null; then
  echo "Bounding journald disk usage..."
  sudo mkdir -p /etc/systemd/journald.conf.d
  echo "$JOURNALD_CONF_DESIRED" | sudo tee "$JOURNALD_CONF" > /dev/null
  sudo systemctl restart systemd-journald
fi

# --- Admission backstop for concurrent agent work (agent-work.slice) ---
#
# The per-command caps in the agent guidance (`scope --max=16G pnpm test`) were
# each measured for a job running ALONE. With a dozen agents across worktrees,
# six concurrent scopes were observed committing ~108G of MemoryMax on a 61G
# box. Nothing arbitrates that, so the failure mode is NOT a kill: the box
# swap-thrashes and jobs stall at a fraction of normal speed while their own
# caps sit unreached, which agents experience as a hung command.
#
# `scope --class=work` puts every such job in this one slice, so MemoryHigh
# applies to their SUM and the kernel reclaims against the aggregate. It
# throttles rather than kills (verified: memory.high events accumulate,
# memory.oom_kill stays 0) — the per-scope MemoryMax still catches a single
# runaway job. MemorySwapMax keeps this slice from driving system swap toward
# exhaustion, the condition behind the 2026-07-16/17 claude-session kills.
#
# Sized for 61G total: ~24G ceiling for ClickHouse, ~5G for claude sessions
# and misc daemons, leaving 32G for the work. Tune live without a reload:
#   systemctl --user set-property agent-work.slice MemoryHigh=<size>
AGENT_SLICE_DIR="$HOME/.config/systemd/user"
mkdir -p "$AGENT_SLICE_DIR"

cat > "$AGENT_SLICE_DIR/agent-work.slice" <<'UNIT'
[Unit]
Description=Expendable agent work (test suites, builds, type-checks)

[Slice]
MemoryHigh=32G
MemorySwapMax=8G
UNIT

systemctl --user daemon-reload

# --- Memory forensics sampler (syshealth memsnap) ---
#
# Neither OOM killer keeps pre-kill history: oomd logs only the victim and an
# aggregate %, and the kernel logs a point-in-time process dump. This timer
# appends one CSV row per user cgroup (claude scopes, clickhouse, dev-server
# scopes, login sessions) plus a _system row every minute — a few ms of
# cgroupfs reads, self-bounded to ~2 weeks — so `syshealth mem` can replay
# who was growing in the hours before any kill. User units, no sudo needed.
MEMSNAP_UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$MEMSNAP_UNIT_DIR"

cat > "$MEMSNAP_UNIT_DIR/syshealth-memsnap.service" <<'UNIT'
[Unit]
Description=Sample per-cgroup memory/swap for syshealth mem

[Service]
Type=oneshot
ExecStart=%h/dotfiles/bin/syshealth mem-sample
UNIT

cat > "$MEMSNAP_UNIT_DIR/syshealth-memsnap.timer" <<'UNIT'
[Unit]
Description=Run syshealth mem-sample every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now syshealth-memsnap.timer

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

# --- /tmp inode-exhaustion prevention ---
#
# /tmp is a 31G tmpfs capped at 1,048,576 inodes. A heavy Node/tsx/pnpm + multi-agent
# workload churns ~250k tiny files/day into /tmp (tsx and node compile caches, pnpm
# spillover, and orphaned tmp-<pid> build dirs left behind when OOM-killed processes
# skip their cleanup). The distro default (/usr/lib/tmpfiles.d/tmp.conf) only reaps
# /tmp entries older than 10 days — far longer than this churn can survive within the
# inode cap — so /tmp hits 100% inodes (ENOSPC for every mkdir/open) while byte usage
# sits near 10%. Two changes fix it: shorter per-cache age thresholds, and running the
# reaper hourly instead of daily.
#
# Aging uses the default clock (atime + ctime + mtime must ALL be older than the age),
# so files a tool is actively reading/writing are never removed — worst case is a cache
# miss + rebuild. Live Claude Code session scratchpads keep fresh mtimes, so the 2-day
# base age never touches an active session; only stale (>2d idle) session dirs age out.
# ("Shorter age wins" for overlapping rules and the tmp-* glob match were both verified
#  on this host with `systemd-tmpfiles --clean --dry-run`.)
#
# Shadowing tmp.conf by basename is the distro-sanctioned override path — the stock file
# comments that the /tmp rules are split out "to make them easier to override". This only
# replaces the two base `q` rules; the exclusions that protect running services' private
# /tmp mounts and other live sockets live in SEPARATE files (systemd-tmp.conf, snapd.conf,
# tmux.conf, openssh-client.conf), which are left untouched and stay active. Verified with
# a merged-set `--clean --dry-run`: systemd-private-*, snap-private-tmp, tmux-*, ssh-*, and
# the X11/ICE socket dirs are all spared (a single-file dry-run misleadingly flags them,
# because passing one file skips every other config's exclusion rules).

TMPFILES_TMP="/etc/tmpfiles.d/tmp.conf"
TMPFILES_TMP_DESIRED='# Managed by dotfiles install-ubuntu.sh. Overrides /usr/lib/tmpfiles.d/tmp.conf.
# Prevents /tmp tmpfs inode exhaustion under heavy Node/tsx/pnpm + multi-agent load.
# Aging = default clock (atime+ctime+mtime all older than age); in-use files are spared.

# Base: reap idle /tmp entries after 2 days (safe margin for live Claude Code sessions).
q /tmp 1777 root root 2d

# High-churn regenerable caches: reap after 12h idle (shorter age overrides the 2d base).
e /tmp/tsx-1000           - - - 12h
e /tmp/node-compile-cache - - - 12h
e /tmp/.pnpm-store        - - - 12h

# Orphaned build/temp dirs from dead (often OOM-killed) processes: reap files after 6h.
e /tmp/tmp-*              - - - 6h

# /var/tmp: unchanged from distro default.
q /var/tmp 1777 root root 30d'
if [ ! -f "$TMPFILES_TMP" ] || ! diff -q <(echo "$TMPFILES_TMP_DESIRED") "$TMPFILES_TMP" &>/dev/null; then
  echo "Installing /tmp inode-cleanup policy ($TMPFILES_TMP)..."
  echo "$TMPFILES_TMP_DESIRED" | sudo tee "$TMPFILES_TMP" > /dev/null
fi

# Run the reaper hourly instead of the distro default of daily.
TMPFILES_TIMER_DIR="/etc/systemd/system/systemd-tmpfiles-clean.timer.d"
TMPFILES_TIMER_OVERRIDE="$TMPFILES_TIMER_DIR/frequent.conf"
TMPFILES_TIMER_DESIRED='[Timer]
OnUnitActiveSec=1h'
if [ ! -f "$TMPFILES_TIMER_OVERRIDE" ] || ! diff -q <(echo "$TMPFILES_TIMER_DESIRED") "$TMPFILES_TIMER_OVERRIDE" &>/dev/null; then
  echo "Setting systemd-tmpfiles cleanup to run hourly..."
  sudo mkdir -p "$TMPFILES_TIMER_DIR"
  echo "$TMPFILES_TIMER_DESIRED" | sudo tee "$TMPFILES_TIMER_OVERRIDE" > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart systemd-tmpfiles-clean.timer
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

# Run PostgreSQL in UTC regardless of host timezone. GUC-based (not a
# postgresql.conf edit) so it applies via reload, no restart needed.
echo "Configuring PostgreSQL timezone (UTC)..."
sudo -u postgres psql -c "ALTER SYSTEM SET timezone TO 'UTC';" > /dev/null
sudo -u postgres psql -c "ALTER SYSTEM SET log_timezone TO 'UTC';" > /dev/null
sudo -u postgres psql -c "SELECT pg_reload_conf();" > /dev/null

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

# --- Server config (exists ONLY to quiet the logger) ---
#
# Without a config file ClickHouse runs on the config embedded in the binary,
# which sets <level>trace</level> + <console>true</console>. Everything then
# goes to stdout -> journald at ~40 lines/sec on an idle server: 3.17M entries
# in 24h on 2026-08-01, 99.4% of ALL journal volume, against 6.4k for the
# next-noisiest unit. journald's rate limiter is per-service and ClickHouse
# shares the per-uid user@.service bucket with every other user unit, so it
# was suppressing ~400-500k messages per 30s window and evicting
# claude-session and memsnap logs as collateral. Every line also carries
# syslog PRIORITY=6 regardless of
# its internal <Trace>/<Information> level, so systemd's LogLevelMax= cannot
# filter it — the level has to be fixed on the ClickHouse side.
#
# The body below is ClickHouse's OWN rendering of the embedded default
# (preprocessed_configs/config.xml) copied verbatim, with only <level>
# changed. Nothing else is altered, so behaviour is identical to running with
# no config file at all. Raise to "information" if a debugging session needs
# query-level detail — that roughly halves the volume rather than removing it;
# "warning" cuts ~99%.
CH_CONFIG_DIR="$(dirname "$CH_CONFIG")"
mkdir -p "$CH_CONFIG_DIR"

cat > "$CH_CONFIG" <<'CHCONF'
<!-- Managed by ~/dotfiles/install-ubuntu.sh. Edits here are overwritten.
     This is ClickHouse's own embedded default config with <level> lowered
     from trace; see the installer for why. -->
<clickhouse>
    <logger>
        <level>warning</level>
        <console>true</console>
    </logger>

    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <mysql_port>9004</mysql_port>
    <postgresql_port>9005</postgresql_port>

    <path>./</path>

    <mlock_executable>true</mlock_executable>

    <!-- Shared-singleton limits. One server backs every worktree and every
         agent, so an unbounded query is not a local problem: it starves
         everyone else's integration suite. All of these default to 0
         (unlimited), which is fine single-tenant and wrong here. -->

    <!-- A query stampede queues instead of exhausting the server. Generous
         for ~12 agents x 8 vitest forks. -->
    <max_concurrent_queries>100</max_concurrent_queries>

    <!-- Default 480s, so a dropped database sits in metadata_dropped/ for
         eight minutes before real deletion. Integration suites create and drop
         test_* / pg_replica_test_* databases fast enough that this leaves a
         standing backlog of dead tables the background pools still track. -->
    <database_atomic_delay_before_drop_table_sec>60</database_atomic_delay_before_drop_table_sec>

    <send_crash_reports>
        <enabled>true</enabled>
        <send_logical_errors>true</send_logical_errors>
        <endpoint>https://crash.clickhouse.com/</endpoint>
    </send_crash_reports>

    <http_options_response>
        <header>
            <name>Access-Control-Allow-Origin</name>
            <value>*</value>
        </header>
        <header>
            <name>Access-Control-Allow-Headers</name>
            <value>origin, x-requested-with, x-clickhouse-format, x-clickhouse-user, x-clickhouse-key, Authorization</value>
        </header>
        <header>
            <name>Access-Control-Allow-Methods</name>
            <value>POST, GET, OPTIONS</value>
        </header>
        <header>
            <name>Access-Control-Max-Age</name>
            <value>86400</value>
        </header>
    </http_options_response>

    <users>
        <default>
            <password/>

            <networks>
                <ip>::/0</ip>
            </networks>

            <profile>default</profile>
            <quota>default</quota>

            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </default>
    </users>

    <!-- Per-query ceilings for the default profile. Deliberately in <profiles>
         and NOT <constraints>, so a client that genuinely needs more can say
         SETTINGS max_memory_usage=... on the query. These are a safety net for
         the shared server, not a wall.

         SIZING, and the mistake to avoid repeating: max_memory_usage was first
         set to 4 GiB on the reasoning that it was ~1000x the largest table
         (~320 KiB). That reasoning is wrong. A query's peak is its working set
         — join build sides and aggregation state — which has almost nothing to
         do with how large the source tables are. The calendar pipeline's
         prematerialize step has 47 JOINs and 18 GROUP BYs over small tables and
         legitimately wants 5-9 GiB, so 4 GiB turned a whole class of local
         integration runs into a standing MEMORY_LIMIT_EXCEEDED baseline.

         The real bound is the SERVER total, not the table sizes:
         max_server_memory_usage is 21.6 GiB (0.9 x the 24 GiB cgroup cap), and
         it cannot simply be raised — 24 GiB for ClickHouse plus 32 GiB for
         agent-work.slice already commits 56 of the box's 61 GiB. Exceeding the
         per-query cap fails ONE query cleanly; exceeding the server total fails
         arbitrary queries belonging to other agents, which is far worse and
         much harder to diagnose. So the per-query ceiling times the realistic
         concurrent-heavy-query count has to fit under 21.6 GiB. -->

    <profiles>
        <default>
            <!-- Without this a runaway query runs forever holding threads and
                 memory; nothing else reclaims it. Verified: a 2 Grow
                 sum(sipHash64(number)) that otherwise takes 38.8s is killed at
                 2.02s with TIMEOUT_EXCEEDED when the limit is 2s.
                 KNOWN LIMIT: the deadline is checked while the query processes
                 data, so it catches CPU/IO-bound runaways (the realistic case
                 here — accidental cross joins, unbounded aggregations) but NOT
                 a query parked in sleep() or blocked on an external wait.
                 Treat it as a runaway catcher, not a hard SLA. -->
            <max_execution_time>300</max_execution_time>
            <!-- 12 GiB, covering the reported 5-9 GiB calendar-pipeline peaks
                 with headroom. Verified: a 150M-key GROUP BY that dies at 4 GiB
                 with MEMORY_LIMIT_EXCEEDED completes in 13.3s here. -->
            <max_memory_usage>12884901888</max_memory_usage>

            <!-- Spill to disk instead of climbing toward that ceiling, at half
                 of max_memory_usage (the ClickHouse convention). A large
                 GROUP BY or ORDER BY writes to <path>/tmp rather than growing
                 in RAM. Slower for queries that trip it, but an integration run
                 that finishes slowly beats one that fails. 571 GiB free on /,
                 so spill space is not a constraint.

                 DO NOT read this as making concurrency free. Measured peak
                 cgroup memory for a SINGLE heavy query was 15 GiB against the
                 24 GiB cap — higher than the 12 GiB per-query ceiling, because
                 memory.current also counts page cache from the spill files.
                 Spilling converts hard anonymous allocations into reclaimable
                 cache, which is a real improvement under pressure, but it does
                 not mean two such queries fit side by side. The standing
                 guidance to serialize integration runs still applies; this
                 raises the per-query ceiling, it does not add capacity. -->
            <max_bytes_before_external_group_by>6442450944</max_bytes_before_external_group_by>
            <max_bytes_before_external_sort>6442450944</max_bytes_before_external_sort>
            <max_bytes_before_external_group_by>6442450944</max_bytes_before_external_group_by>
            <max_bytes_before_external_sort>6442450944</max_bytes_before_external_sort>
        </default>
    </profiles>

    <quotas>
        <default/>
    </quotas>

    <user_directories>
        <users_xml>
            <path>config.xml</path>
        </users_xml>
        <local_directory>
            <path>access/</path>
        </local_directory>
    </user_directories>

    <access_control_improvements>
        <users_without_row_policies_can_read_rows>true</users_without_row_policies_can_read_rows>
        <on_cluster_queries_require_cluster_grant>true</on_cluster_queries_require_cluster_grant>
        <select_from_system_db_requires_grant>true</select_from_system_db_requires_grant>
        <select_from_information_schema_requires_grant>true</select_from_information_schema_requires_grant>
        <settings_constraints_replace_previous>true</settings_constraints_replace_previous>
        <table_engines_require_grant>true</table_engines_require_grant>
        <enable_read_write_grants>true</enable_read_write_grants>
        <enable_user_name_access_type>true</enable_user_name_access_type>
        <throw_on_invalid_replicated_access_entities>true</throw_on_invalid_replicated_access_entities>
    </access_control_improvements>
</clickhouse>
CHCONF

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
Environment=TZ=UTC
ExecStart=${CH_BIN} server --config-file=${CH_CONFIG} -- --path=${CH_DATA}/
WorkingDirectory=${CH_DATA}
Restart=on-failure

# Give ClickHouse its OWN journald rate-limit bucket. Without this it shares
# the per-uid user@.service bucket with every other user unit, so its volume
# suppressed ~400-500k messages per 30s window and took claude-session and
# memsnap logs down with it. Confining the limit here means a ClickHouse flood
# can only ever cost ClickHouse's own lines.
LogRateLimitIntervalSec=30s
LogRateLimitBurst=2000

# Never let ClickHouse take down the box: uncapped, it peaked at 51.6G mem
# + 10.6G swap (2026-07-16) and helped drive system swap to 99.8%, where
# systemd-oomd kills the swap-heaviest scopes (a claude session died first).
# ClickHouse reads the cgroup limit to size max_server_memory_usage, so big
# queries fail with MEMORY_LIMIT_EXCEEDED instead of the kernel OOM-killing
# the server.
#
# MemoryHigh MUST stay ABOVE max_server_memory_usage, which ClickHouse derives
# at startup as 0.9 x MemoryMax (24G -> 21.6G). It reads memory.max, NOT
# memory.high, so a memory.high set below that figure is invisible to it: it
# keeps allocating toward 21.6G while the kernel reclaims from the lower
# ceiling, and the two fight forever. That is not a theoretical ordering —
# a hand-set MemoryHigh=14G put the server in exactly that state on
# 2026-08-01: 319M memory.high events, 36M major faults, its 4G swap
# allowance exhausted with 6M failed swap attempts, memory.pressure "full"
# at 94% for hours, ~6 cores burned entirely on reclaim, and the HTTP port
# timing out — all while 20G sat free on the box. Raising the ceiling to 22G
# dropped pressure to 0.07% and the footprint to 2.5G within a minute: the
# 15G it appeared to "need" was reclaim churn, not working set.
#
# So: 22G high < 24G max, with 21.6G of self-limit in between. ClickHouse's
# own limiter fires first (clean MEMORY_LIMIT_EXCEEDED), memory.high is the
# backstop, and memory.max is the wall. MemorySwapMax=8G leaves room to park
# cold pages — at 4G it filled completely and forced reclaim to come out of
# the active set, which is what turned throttling into a refault treadmill.
MemoryHigh=22G
MemoryMax=24G
MemorySwapMax=8G

[Install]
WantedBy=default.target
UNIT

# Drop any persistent overrides left by `systemctl --user set-property`. That
# command writes to user.control/, which SHADOWS the unit file above — so a
# one-off tuning during an incident silently becomes the permanent config and
# this installer stops being authoritative. That is how MemoryHigh ended up
# pinned at 14G while the unit file said 20G. To tune without leaving a
# landmine, pass --runtime (cleared on reboot); to change it for good, edit
# the unit above.
CH_CONTROL_DIR="$HOME/.config/systemd/user.control/clickhouse-server.service.d"
if [ -d "$CH_CONTROL_DIR" ]; then
  echo "Removing set-property overrides shadowing clickhouse-server.service..."
  rm -rf "$CH_CONTROL_DIR"
fi

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
