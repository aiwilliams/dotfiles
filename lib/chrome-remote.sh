#!/usr/bin/env bash
# chrome-remote.sh — Bridge Chrome DevTools across a Mac/headless-VM pair.
#
# Lets an AI agent on a headless dev VM drive a Chrome instance running on the
# user's Mac via the Chrome DevTools Protocol. Two halves of the same command:
#
#   On the Mac (UI host):
#     - Launches Chrome with --remote-debugging-port and a dedicated profile
#       (Chrome 136+ refuses --remote-debugging-port against the default
#       user-data-dir, so we use ~/chrome-debug-profile).
#     - Opens an SSH reverse tunnel exposing that port on the headless VM,
#       so the agent there can hit http://localhost:9222 locally.
#
#   On the headless VM:
#     - Reports whether the bridge is up (curl /json/version).
#     - Prints the chrome-devtools-mcp registration snippet.
#     - Tells the user what to run on their Mac when the bridge is down.
#
# Defaults assume the `opine.localhost` convention used by `wt proxy`: when
# Caddy is running with `wt proxy --host <vm> <id>`, the upstream host is the
# VM hosting the dev server, which is also the SSH reverse-tunnel target.

CHROME_REMOTE_PORT_DEFAULT=9222
# shellcheck disable=SC2034  # consumed by bin/wt
CHROME_REMOTE_DOMAIN_DEFAULT="opine.localhost"
CHROME_REMOTE_PROFILE_DIR="${HOME}/chrome-debug-profile"
CHROME_REMOTE_MAC_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# ----------------------------------------------------------------------------
# Role detection
# ----------------------------------------------------------------------------

chrome_remote_is_mac() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# Headless Linux: no X11 and no Wayland display. Catches both bare VMs and
# SSH sessions onto desktop Linux boxes, which is the desired behavior — even
# if the box has a UI, the agent in this SSH session can't drive it.
chrome_remote_is_headless_linux() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]
}

# Best-effort identifier for this machine, preferring the Tailscale hostname
# (unambiguous across the tailnet) and falling back to `hostname`.
chrome_remote_host_label() {
  local bin
  bin=$(_chrome_remote_tailscale_bin)
  if [[ -n "$bin" ]]; then
    local label
    label=$("$bin" status --self --json 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('HostName',''))" 2>/dev/null) || true
    if [[ -n "$label" ]]; then
      echo "$label"
      return
    fi
  fi
  hostname -s 2>/dev/null || hostname
}

_chrome_remote_tailscale_bin() {
  if command -v tailscale &>/dev/null; then
    command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

# ----------------------------------------------------------------------------
# Chrome (Mac only)
# ----------------------------------------------------------------------------

chrome_remote_chrome_alive() {
  local port="${1:-$CHROME_REMOTE_PORT_DEFAULT}"
  curl -sf -o /dev/null --max-time 1 "http://localhost:${port}/json/version"
}

chrome_remote_chrome_browser() {
  local port="${1:-$CHROME_REMOTE_PORT_DEFAULT}"
  curl -sf --max-time 1 "http://localhost:${port}/json/version" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('Browser','?'))" 2>/dev/null
}

chrome_remote_chrome_pid() {
  local port="${1:-$CHROME_REMOTE_PORT_DEFAULT}"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1
}

chrome_remote_chrome_start() {
  local port="${1:-$CHROME_REMOTE_PORT_DEFAULT}"

  if chrome_remote_chrome_alive "$port"; then
    return 0
  fi

  if [[ ! -x "$CHROME_REMOTE_MAC_BIN" ]]; then
    echo -e "${RED}Google Chrome not found at:${NC}" >&2
    echo "  $CHROME_REMOTE_MAC_BIN" >&2
    return 1
  fi

  mkdir -p "$CHROME_REMOTE_PROFILE_DIR"
  "$CHROME_REMOTE_MAC_BIN" \
    --remote-debugging-port="$port" \
    --user-data-dir="$CHROME_REMOTE_PROFILE_DIR" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true

  local waited=0
  while (( waited++ < 10 )); do
    if chrome_remote_chrome_alive "$port"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

chrome_remote_chrome_stop() {
  local port="${1:-$CHROME_REMOTE_PORT_DEFAULT}"
  local pid
  pid=$(chrome_remote_chrome_pid "$port")
  [[ -z "$pid" ]] && return 0
  kill "$pid" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# SSH reverse tunnel (Mac only)
# ----------------------------------------------------------------------------

chrome_remote_tunnel_pids() {
  local host="$1" user="$2" port="$3"
  pgrep -f "ssh.*-R[[:space:]]*${port}:localhost:${port}.*${user}@${host}" 2>/dev/null || true
}

chrome_remote_tunnel_start() {
  local host="$1" user="$2" port="$3"

  if [[ -n "$(chrome_remote_tunnel_pids "$host" "$user" "$port")" ]]; then
    return 0
  fi

  # ExitOnForwardFailure fails loudly if the remote port is already taken,
  # rather than silently sitting with a useless connection.
  ssh -fN \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "${port}:localhost:${port}" \
    "${user}@${host}"
}

chrome_remote_tunnel_stop() {
  local host="$1" user="$2" port="$3"
  local pids
  pids=$(chrome_remote_tunnel_pids "$host" "$user" "$port")
  [[ -z "$pids" ]] && return 0
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

chrome_remote_print_mcp_snippet() {
  local port="$1"
  cat <<EOF
  Register the MCP server (once, on this VM):

    claude mcp add chrome-attached -- \\
      npx -y chrome-devtools-mcp@latest --browserUrl=http://localhost:${port}

  Tools then appear as mcp__chrome-attached__* (list_pages, navigate_page,
  take_snapshot, hover, evaluate_script, take_screenshot, ...).
EOF
}

# ----------------------------------------------------------------------------
# Mac-side actions
# ----------------------------------------------------------------------------

chrome_remote_mac_status() {
  local host="$1" user="$2" port="$3" domain="$4" listen_port="$5"

  echo -e "${BOLD}chrome-remote (mac)${NC}"
  echo ""

  if chrome_remote_chrome_alive "$port"; then
    local browser
    browser=$(chrome_remote_chrome_browser "$port")
    echo -e "  Chrome:      ${GREEN}listening${NC} on localhost:${port} (${browser})"
    echo -e "  ${DIM}profile:     ${CHROME_REMOTE_PROFILE_DIR}${NC}"
  else
    echo -e "  Chrome:      ${YELLOW}not running${NC}"
  fi

  if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
    echo -e "  SSH tunnel:  ${DIM}n/a (host=localhost)${NC}"
  else
    local tunnel_pids
    tunnel_pids=$(chrome_remote_tunnel_pids "$host" "$user" "$port")
    if [[ -n "$tunnel_pids" ]]; then
      local pids_csv
      # shellcheck disable=SC2086
      pids_csv=$(echo $tunnel_pids | tr ' ' ',')
      echo -e "  SSH tunnel:  ${GREEN}up${NC} ${user}@${host} ⇐ localhost:${port} (pid ${pids_csv})"
    else
      echo -e "  SSH tunnel:  ${YELLOW}not running${NC} (target: ${user}@${host}:${port})"
    fi
  fi

  echo ""
  if [[ -n "$domain" ]]; then
    echo -e "  ${BOLD}App URL:${NC}    https://${domain}:${listen_port}"
  fi
  echo -e "  ${DIM}Start with:  wt chrome-remote start${NC}"
}

chrome_remote_mac_start() {
  local host="$1" user="$2" port="$3" domain="$4" listen_port="$5"

  echo -e "${BOLD}Starting chrome-remote bridge${NC}"
  echo ""

  echo -n "  Chrome (port ${port}): "
  if chrome_remote_chrome_alive "$port"; then
    echo -e "${GREEN}already running${NC}"
  elif chrome_remote_chrome_start "$port"; then
    echo -e "${GREEN}started${NC}"
  else
    echo -e "${RED}failed${NC}"
    echo -e "${YELLOW}  Could not bring up DevTools on port ${port}.${NC}"
    echo -e "${DIM}  Chrome 136+ refuses --remote-debugging-port against the default profile;${NC}"
    echo -e "${DIM}  this command launches with --user-data-dir=${CHROME_REMOTE_PROFILE_DIR}.${NC}"
    return 1
  fi

  if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
    echo -e "  SSH tunnel: ${DIM}skipped (host=localhost)${NC}"
  else
    echo -n "  SSH tunnel to ${user}@${host}: "
    if [[ -n "$(chrome_remote_tunnel_pids "$host" "$user" "$port")" ]]; then
      echo -e "${GREEN}already running${NC}"
    elif chrome_remote_tunnel_start "$host" "$user" "$port"; then
      echo -e "${GREEN}started${NC}"
    else
      echo -e "${RED}failed${NC}"
      echo "  Try manually: ssh -fN -o ExitOnForwardFailure=yes -R ${port}:localhost:${port} ${user}@${host}"
      return 1
    fi
  fi

  echo ""
  if [[ -n "$domain" ]]; then
    echo -e "  ${BOLD}Open in Chrome:${NC} https://${domain}:${listen_port}"
  fi
  echo -e "  ${DIM}First time on this profile? You'll need to sign in.${NC}"
  if [[ "$host" != "localhost" && "$host" != "127.0.0.1" ]]; then
    echo -e "  ${DIM}Verify from ${user}@${host}: curl -s http://localhost:${port}/json/version${NC}"
  fi
}

chrome_remote_mac_stop() {
  local host="$1" user="$2" port="$3" with_chrome="$4"

  echo -e "${BOLD}Stopping chrome-remote bridge${NC}"

  if [[ "$host" != "localhost" && "$host" != "127.0.0.1" ]]; then
    if [[ -n "$(chrome_remote_tunnel_pids "$host" "$user" "$port")" ]]; then
      chrome_remote_tunnel_stop "$host" "$user" "$port"
      echo -e "  ${YELLOW}SSH tunnel:${NC} stopped"
    else
      echo -e "  ${DIM}SSH tunnel: not running${NC}"
    fi
  fi

  if [[ "$with_chrome" == "true" ]]; then
    if chrome_remote_chrome_alive "$port"; then
      chrome_remote_chrome_stop "$port"
      echo -e "  ${YELLOW}Chrome:${NC} stopped"
    else
      echo -e "  ${DIM}Chrome: not running${NC}"
    fi
  elif chrome_remote_chrome_alive "$port"; then
    echo -e "  ${DIM}Chrome left running. Pass --with-chrome to stop it too.${NC}"
  fi
}

# ----------------------------------------------------------------------------
# Headless-Linux-side actions
# ----------------------------------------------------------------------------

chrome_remote_linux_status() {
  local port="$1" suggested_user="$2"

  echo -e "${BOLD}chrome-remote (headless linux)${NC}"
  echo ""

  local label
  label=$(chrome_remote_host_label)

  if chrome_remote_chrome_alive "$port"; then
    local browser
    browser=$(chrome_remote_chrome_browser "$port")
    echo -e "  Bridge: ${GREEN}up${NC} — http://localhost:${port} (${browser})"
    echo ""
    chrome_remote_print_mcp_snippet "$port"
  else
    echo -e "  Bridge: ${YELLOW}localhost:${port} unreachable${NC}"
    echo ""
    echo -e "  ${BOLD}On your Mac, run:${NC}"
    echo ""
    echo -e "    ${GREEN}wt chrome-remote start --host ${label} --user ${suggested_user}${NC}"
    echo ""
    echo "  That will:"
    echo "    1. Launch Chrome with --remote-debugging-port=${port} on the Mac"
    echo "    2. SSH-tunnel Mac's localhost:${port} → ${label}:${port}"
    echo ""
    echo -e "  ${DIM}Raw equivalent (if wt isn't installed on the Mac):${NC}"
    echo -e "    ${DIM}mkdir -p ~/chrome-debug-profile${NC}"
    echo -e "    ${DIM}/Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome${NC} \\"
    echo -e "    ${DIM}  --remote-debugging-port=${port}${NC} \\"
    echo -e "    ${DIM}  --user-data-dir=\"\$HOME/chrome-debug-profile\" &${NC}"
    echo -e "    ${DIM}ssh -fN -o ExitOnForwardFailure=yes -R ${port}:localhost:${port} ${suggested_user}@${label}${NC}"
  fi
}
