#!/usr/bin/env bash
# caddy.sh — Shared Caddy reverse-proxy library for dev-proxy.
# Sourced (not executed) by bin/dev-proxy.

CADDY_DATA_DIR="${HOME}/.local/share/dev-proxy/caddy"
CADDY_CERT_DIR="${HOME}/.local/share/dev-proxy/certs"
CADDY_PIDFILE="${CADDY_DATA_DIR}/caddy.pid"
CADDYFILE="${CADDY_DATA_DIR}/Caddyfile"

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

caddy_check() {
  command -v caddy &>/dev/null
}

# Check if certs exist for a given domain.
# $1 = domain (e.g. opine.test)
caddy_certs_exist() {
  local domain="${1:-}"
  if [[ -n "$domain" ]]; then
    [[ -f "$CADDY_CERT_DIR/${domain}.pem" && -f "$CADDY_CERT_DIR/${domain}-key.pem" ]]
  else
    # Check if any cert files exist
    compgen -G "$CADDY_CERT_DIR/*.pem" > /dev/null 2>&1
  fi
}

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

# Write a Caddyfile that routes $domain:$listen_port to $upstream_host:$upstream_port.
# $1 = domain (e.g. opine.test)
# $2 = listen port (e.g. 5000)
# $3 = upstream host (e.g. localhost or fw)
# $4 = upstream port (e.g. 3001)
caddy_write_config() {
  local domain="$1"
  local listen_port="$2"
  local upstream_host="$3"
  local upstream_port="$4"

  mkdir -p "$CADDY_DATA_DIR"

  cat > "$CADDYFILE" <<EOF
{
    auto_https disable_redirects
}

${domain}:${listen_port} {
    tls ${CADDY_CERT_DIR}/${domain}.pem ${CADDY_CERT_DIR}/${domain}-key.pem
    reverse_proxy ${upstream_host}:${upstream_port} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
}

# --------------------------------------------------------------------------
# Process management
# --------------------------------------------------------------------------

caddy_is_running() {
  if [[ -f "$CADDY_PIDFILE" ]]; then
    local pid
    pid=$(cat "$CADDY_PIDFILE")
    kill -0 "$pid" 2>/dev/null && return 0
    # Stale pidfile
    rm -f "$CADDY_PIDFILE"
  fi
  return 1
}

# Start Caddy. Optionally pass a domain to check for certs.
# $1 = domain (optional, for cert existence check)
# shellcheck disable=SC2120
caddy_start() {
  local domain="${1:-}"

  if ! caddy_check; then
    echo "caddy is not installed." >&2
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "  brew install caddy" >&2
    else
      echo "  sudo apt install caddy  # or see https://caddyserver.com/docs/install" >&2
    fi
    return 1
  fi

  if ! caddy_certs_exist "$domain"; then
    echo "Certificates not found at $CADDY_CERT_DIR" >&2
    if [[ -n "$domain" ]]; then
      echo "Generate them with: bash apps/platform/scripts/setup-local-certs.sh $domain" >&2
    else
      echo "Generate them with: bash apps/platform/scripts/setup-local-certs.sh <domain>" >&2
    fi
    return 1
  fi

  if ! [[ -f "$CADDYFILE" ]]; then
    echo "No Caddyfile found. Run dev-proxy with a target first." >&2
    return 1
  fi

  if caddy_is_running; then
    # Already running — just reload
    caddy_reload
    return
  fi

  caddy start --config "$CADDYFILE" --pidfile "$CADDY_PIDFILE" 2>/dev/null
}

caddy_stop() {
  if caddy_is_running; then
    caddy stop 2>/dev/null || true
    rm -f "$CADDY_PIDFILE"
  fi
}

caddy_reload() {
  if caddy_is_running; then
    caddy reload --config "$CADDYFILE" 2>/dev/null
  else
    caddy_start
  fi
}

caddy_status() {
  if caddy_is_running; then
    if [[ -f "$CADDYFILE" ]]; then
      local upstream
      upstream=$(grep -oP 'reverse_proxy \K\S+' "$CADDYFILE" 2>/dev/null || echo "unknown")
      local domain
      domain=$(grep -oP '^\S+\s*\{' "$CADDYFILE" | grep -v '^{' | head -1 | sed 's/ *{//')
      echo "running: https://${domain} → ${upstream}"
    else
      echo "running (no config)"
    fi
  else
    echo "stopped"
  fi
}
