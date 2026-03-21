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

# Print current tunnel status by querying ngrok's local API.
ngrok_status() {
  if ! ngrok_is_running; then
    echo "stopped (${NGROK_DOMAIN:-(NGROK_DOMAIN not set)})"
    return
  fi

  local response
  response=$(curl -s "$NGROK_API/tunnels" 2>/dev/null) || {
    echo "running (API not ready)"
    return
  }

  local url backend
  url=$(echo "$response" | grep -oP '"public_url"\s*:\s*"\K[^"]+' | head -1)
  backend=$(echo "$response" | grep -oP '"addr"\s*:\s*"\K[^"]+' | head -1)

  if [[ -n "$url" && -n "$backend" ]]; then
    echo "running: ${url} → ${backend}"
  else
    echo "running (tunnel starting...)"
  fi
}
