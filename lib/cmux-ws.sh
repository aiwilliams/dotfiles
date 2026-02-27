#!/usr/bin/env bash
# cmux-ws.sh — Shared library for cmux workspace manager.
# Sourced (not executed) by bin/cmux-ws.

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

CMUX_WS_DIR="${CMUX_WS_DIR:-$HOME/.cmux-workspaces}"
CMUX_WS_CONFIG_DIR="$CMUX_WS_DIR/workspaces"
CMUX_WS_STATE_DIR="$CMUX_WS_DIR/state"
CMUX_WS_PANE_MAPS_DIR="$CMUX_WS_STATE_DIR/pane-maps"

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BOLD='\033[1m'
export NC='\033[0m'

# --------------------------------------------------------------------------
# Flags (set by CLI before sourcing)
# --------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

require_cmd() {
  local cmd="$1"
  local install_hint="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Required command not found: ${cmd}${NC}" >&2
    [[ -n "$install_hint" ]] && echo "  Install: $install_hint" >&2
    exit 1
  fi
}

require_cmux_ws_dir() {
  if [[ ! -d "$CMUX_WS_DIR/.git" ]]; then
    echo -e "${RED}Workspace directory not initialized.${NC}" >&2
    echo "Run: cmux-ws init" >&2
    exit 1
  fi
}

# --------------------------------------------------------------------------
# cmux API wrappers
# --------------------------------------------------------------------------

cmux_api() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${YELLOW}cmux $*${NC}" >&2
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] cmux $*" >&2
    return 0
  fi
  cmux "$@"
}

cmux_api_json() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${YELLOW}cmux $* --json${NC}" >&2
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] cmux $* --json" >&2
    echo "[]"
    return 0
  fi
  cmux "$@" --json
}

cmux_new_workspace() {
  cmux_api new-workspace
}

cmux_current_workspace() {
  cmux_api_json current-workspace
}

cmux_list_workspaces() {
  cmux_api_json list-workspaces
}

cmux_list_surfaces() {
  local workspace_id="${1:-}"
  if [[ -n "$workspace_id" ]]; then
    cmux_api_json list-surfaces --workspace "$workspace_id"
  else
    cmux_api_json list-surfaces
  fi
}

cmux_focus_surface() {
  local surface_id="$1"
  cmux_api focus-surface --surface "$surface_id"
}

cmux_new_split() {
  local direction="$1"
  cmux_api new-split "$direction"
}

cmux_send_text() {
  local surface_id="$1"
  local text="$2"
  cmux_api send-surface --surface "$surface_id" "$text"
}

cmux_send_key() {
  local surface_id="$1"
  local key="$2"
  cmux_api send-key-surface --surface "$surface_id" "$key"
}

cmux_send_command() {
  local surface_id="$1"
  local dir="$2"
  local command="$3"

  if [[ -n "$dir" ]]; then
    local expanded_dir="${dir/#\~/$HOME}"
    cmux_send_text "$surface_id" "cd ${expanded_dir}"
    cmux_send_key "$surface_id" enter
    sleep 0.2
  fi

  if [[ -n "$command" ]]; then
    cmux_send_text "$surface_id" "$command"
    cmux_send_key "$surface_id" enter
  fi
}

# --------------------------------------------------------------------------
# YAML parsing (requires yq + jq)
# --------------------------------------------------------------------------

parse_workspace_config() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}Config not found: ${config_file}${NC}" >&2
    return 1
  fi
  yq -o=json "$config_file"
}

config_get_name() {
  echo "$1" | jq -r '.name'
}

config_get_focus() {
  echo "$1" | jq -r '.focus // empty'
}

config_get_pane_count() {
  echo "$1" | jq '.panes | length'
}

config_get_pane_field() {
  local json="$1" index="$2" field="$3"
  echo "$json" | jq -r ".panes[$index].$field // empty"
}

# --------------------------------------------------------------------------
# State file I/O
# --------------------------------------------------------------------------

ensure_state_dirs() {
  mkdir -p "$CMUX_WS_STATE_DIR" "$CMUX_WS_PANE_MAPS_DIR"
}

state_save_workspace_id() {
  local name="$1" workspace_id="$2"
  ensure_state_dirs
  local state_file="$CMUX_WS_STATE_DIR/name-to-id.json"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$state_file" ]]; then
    jq --arg name "$name" --arg id "$workspace_id" \
      '.[$name] = {"workspace_id": $id}' "$state_file" > "$tmp"
  else
    jq -n --arg name "$name" --arg id "$workspace_id" \
      '{($name): {"workspace_id": $id}}' > "$tmp"
  fi
  mv "$tmp" "$state_file"
}

state_get_workspace_id() {
  local name="$1"
  local state_file="$CMUX_WS_STATE_DIR/name-to-id.json"
  if [[ ! -f "$state_file" ]]; then
    return 1
  fi
  jq -r --arg name "$name" '.[$name].workspace_id // empty' "$state_file"
}

state_save_pane_map() {
  local name="$1" pane_id="$2" surface_id="$3"
  ensure_state_dirs
  local map_file="$CMUX_WS_PANE_MAPS_DIR/${name}.json"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$map_file" ]]; then
    jq --arg pane "$pane_id" --arg surface "$surface_id" \
      '.[$pane] = $surface' "$map_file" > "$tmp"
  else
    jq -n --arg pane "$pane_id" --arg surface "$surface_id" \
      '{($pane): $surface}' > "$tmp"
  fi
  mv "$tmp" "$map_file"
}

state_get_surface_id() {
  local name="$1" pane_id="$2"
  local map_file="$CMUX_WS_PANE_MAPS_DIR/${name}.json"
  if [[ ! -f "$map_file" ]]; then
    return 1
  fi
  jq -r --arg pane "$pane_id" '.[$pane] // empty' "$map_file"
}

state_get_pane_map() {
  local name="$1"
  local map_file="$CMUX_WS_PANE_MAPS_DIR/${name}.json"
  if [[ -f "$map_file" ]]; then
    cat "$map_file"
  else
    echo "{}"
  fi
}

# --------------------------------------------------------------------------
# Config file helpers
# --------------------------------------------------------------------------

config_file_for() {
  echo "$CMUX_WS_CONFIG_DIR/${1}.yaml"
}

config_exists() {
  [[ -f "$(config_file_for "$1")" ]]
}

list_configs() {
  if [[ ! -d "$CMUX_WS_CONFIG_DIR" ]]; then
    return
  fi
  for f in "$CMUX_WS_CONFIG_DIR"/*.yaml; do
    [[ -f "$f" ]] || continue
    basename "$f" .yaml
  done
}

# --------------------------------------------------------------------------
# Surface ID helpers
# --------------------------------------------------------------------------

# Extract surface IDs from list-surfaces JSON (one per line, sorted).
# Handles both {id: ...} and {uuid: ...} shapes.
extract_surface_ids() {
  jq -r '.[] | (.id // .uuid // empty)' | sort
}

# Find surface ID(s) present in "after" but not "before".
# Args: file_before file_after (files with one ID per line, sorted)
find_new_surface_ids() {
  comm -13 "$1" "$2"
}

# --------------------------------------------------------------------------
# Temp-file-based pane→surface map (bash 3 compatible)
# --------------------------------------------------------------------------

# Create a fresh map file; prints its path.
pane_map_create() {
  mktemp -t cmux-ws-pane-map.XXXXXX
}

# Store pane_id → surface_id in map file.
pane_map_set() {
  local map_file="$1" pane_id="$2" surface_id="$3"
  echo "${pane_id}=${surface_id}" >> "$map_file"
}

# Look up surface_id for a pane_id from map file.
pane_map_get() {
  local map_file="$1" pane_id="$2"
  grep "^${pane_id}=" "$map_file" | tail -1 | cut -d= -f2-
}
