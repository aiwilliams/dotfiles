#!/usr/bin/env bash
# ngrok.sh — Shared ngrok tunnel library.
# Sourced by bin/wt and other scripts that manage ngrok tunnels.
#
# Expects NGROK_DOMAIN to be set in the environment (e.g. via ~/.zshenv.local):
#   export NGROK_DOMAIN="your-domain.ngrok-free.app"

NGROK_DATA_DIR="${HOME}/.local/share/dev-proxy/ngrok"
NGROK_PIDFILE="${NGROK_DATA_DIR}/ngrok.pid"
NGROK_LOGFILE="${NGROK_DATA_DIR}/ngrok.log"
NGROK_API="http://localhost:4040/api"

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

ngrok_check() {
  command -v ngrok &>/dev/null
}

ngrok_domain() {
  echo "${NGROK_DOMAIN:-}"
}

# --------------------------------------------------------------------------
# Process management
# --------------------------------------------------------------------------

ngrok_is_running() {
  if [[ -f "$NGROK_PIDFILE" ]]; then
    local pid
    pid=$(cat "$NGROK_PIDFILE")
    kill -0 "$pid" 2>/dev/null && return 0
    # Stale pidfile
    rm -f "$NGROK_PIDFILE"
  fi
  return 1
}

# Start ngrok tunneling to a given host:port.
# $1 = upstream host (e.g. localhost, fw)
# $2 = upstream port (e.g. 3001)
ngrok_start() {
  local upstream_host="$1"
  local port="$2"
  local domain
  domain=$(ngrok_domain)

  if ! ngrok_check; then
    echo "ngrok is not installed." >&2
    echo "  See https://ngrok.com/download" >&2
    return 1
  fi

  if [[ -z "$domain" ]]; then
    echo "NGROK_DOMAIN is not set." >&2
    echo "Add to ~/.zshenv.local:  export NGROK_DOMAIN=\"your-domain.ngrok-free.app\"" >&2
    return 1
  fi

  if ngrok_is_running; then
    ngrok_stop
  fi

  mkdir -p "$NGROK_DATA_DIR"
  : > "$NGROK_LOGFILE"

  nohup ngrok http \
    --url "https://${domain}" \
    --log "$NGROK_LOGFILE" \
    --log-format json \
    "https://${upstream_host}:${port}" \
    > /dev/null 2>&1 &

  echo $! > "$NGROK_PIDFILE"
}

ngrok_stop() {
  if ngrok_is_running; then
    local pid
    pid=$(cat "$NGROK_PIDFILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$NGROK_PIDFILE"
  fi
}

# --------------------------------------------------------------------------
# Orphan detection
# --------------------------------------------------------------------------

# Find ngrok pids not tracked by our pidfile.
# Prints one pid per line, or nothing.
ngrok_orphan_pids() {
  local tracked_pid=""
  if [[ -f "$NGROK_PIDFILE" ]]; then
    tracked_pid=$(cat "$NGROK_PIDFILE")
  fi
  local pid
  while read -r pid; do
    [[ "$pid" == "$tracked_pid" ]] && continue
    echo "$pid"
  done < <(pgrep -f 'ngrok http' 2>/dev/null || true)
}

# --------------------------------------------------------------------------
# Startup verification
# --------------------------------------------------------------------------

# Wait for ngrok to either establish a tunnel or fail.
# Returns 0 on success, 1 on failure (with error printed to stderr).
ngrok_wait_or_fail() {
  local pid
  [[ -f "$NGROK_PIDFILE" ]] || { echo "no pidfile" >&2; return 1; }
  pid=$(cat "$NGROK_PIDFILE")

  local _attempt
  for _attempt in $(seq 1 20); do
    # Process died — extract error from log
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$NGROK_PIDFILE"
      _ngrok_print_log_error >&2
      return 1
    fi

    # Process alive — try API
    local response
    response=$(curl -s "$NGROK_API/tunnels" 2>/dev/null) || { sleep 0.25; continue; }
    local url
    url=$(echo "$response" | sed -n 's/.*"public_url" *: *"\([^"]*\)".*/\1/p' | head -1)
    if [[ -n "$url" ]]; then
      return 0
    fi
    sleep 0.25
  done

  # Still running but no tunnel after ~5s — check log for errors
  if grep -q '"lvl":"eror"' "$NGROK_LOGFILE" 2>/dev/null; then
    _ngrok_print_log_error >&2
    return 1
  fi
  # Probably just slow
  return 0
}

# Extract the last error message from the ngrok JSON log.
_ngrok_print_log_error() {
  [[ -f "$NGROK_LOGFILE" ]] || return
  local err
  err=$(grep '"lvl":"eror"\|"lvl":"crit"' "$NGROK_LOGFILE" | tail -1 \
    | sed -n 's/.*"err" *: *"\([^"]*\)".*/\1/p' || true)
  if [[ -n "$err" ]]; then
    # Unescape JSON newlines for readability
    echo "${err//\\n/$'\n'}"
  else
    echo "ngrok failed — check log: $NGROK_LOGFILE"
  fi
}

# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------

# Print current tunnel status by querying ngrok's local API.
ngrok_status() {
  local has_tracked=false

  if ngrok_is_running; then
    has_tracked=true
    local pid
    pid=$(cat "$NGROK_PIDFILE")
    local uptime
    uptime=$(_ngrok_uptime "$pid")

    local response
    response=$(curl -s "$NGROK_API/tunnels" 2>/dev/null) || true

    local url backend
    url=$(echo "$response" | sed -n 's/.*"public_url" *: *"\([^"]*\)".*/\1/p' | head -1)
    backend=$(echo "$response" | sed -n 's/.*"addr" *: *"\([^"]*\)".*/\1/p' | head -1)

    if [[ -n "$url" && -n "$backend" ]]; then
      echo "  status:  running"
      echo "  tunnel:  ${url} → ${backend}"
    else
      echo "  status:  running (tunnel starting…)"
    fi
    echo "  pid:     ${pid} (up ${uptime})"
    echo "  log:     ${NGROK_LOGFILE}"
  fi

  # Orphan detection
  local -a orphans=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && orphans+=("$pid")
  done < <(ngrok_orphan_pids)

  if [[ ${#orphans[@]} -gt 0 ]]; then
    if ! $has_tracked; then
      echo "  status:  stopped (no tracked tunnel)"
    fi
    echo ""
    echo "  ⚠ orphan ngrok processes (not started by wt):"
    local pid
    for pid in "${orphans[@]}"; do
      local cmd uptime
      cmd=$(ps -o args= -p "$pid" 2>/dev/null | sed 's/^/    /')
      uptime=$(_ngrok_uptime "$pid")
      echo "    pid ${pid} (up ${uptime})"
      [[ -n "$cmd" ]] && echo "  ${cmd}"
    done
    echo ""
    echo "  Kill with:  kill ${orphans[*]}"
  elif ! $has_tracked; then
    echo "  status:  stopped"
  fi

  echo "  domain:  ${NGROK_DOMAIN:-(NGROK_DOMAIN not set)}"
}

# Human-readable uptime for a pid. Portable across macOS and Linux: parses
# `ps -o etime=` ([[DD-]HH:]MM:SS), since macOS ps lacks the `etimes` keyword.
_ngrok_uptime() {
  local pid="$1"
  local et
  et=$(ps -o etime= -p "$pid" 2>/dev/null) || { echo "?"; return; }
  et="${et//[[:space:]]/}"
  [[ -n "$et" ]] || { echo "?"; return; }

  local days=0
  if [[ "$et" == *-* ]]; then
    days="${et%%-*}"
    et="${et#*-}"
  fi
  local hours=0 mins=0 secs=0
  local -a parts
  IFS=: read -ra parts <<< "$et"
  case ${#parts[@]} in
    3) hours="${parts[0]}" mins="${parts[1]}" secs="${parts[2]}" ;;
    2) mins="${parts[0]}" secs="${parts[1]}" ;;
    *) echo "?"; return ;;
  esac

  local elapsed=$(( 10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs ))
  if (( elapsed < 60 )); then
    echo "${elapsed}s"
  elif (( elapsed < 3600 )); then
    echo "$(( elapsed / 60 ))m"
  else
    echo "$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
  fi
}
