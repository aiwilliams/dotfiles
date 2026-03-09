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
# cmux CLI resolution
# --------------------------------------------------------------------------

# The cmux app bundles the CLI at Resources/bin/cmux. The binary at
# Contents/MacOS/cmux is the GUI app and crashes when invoked as a CLI.
CMUX_APP_CLI="/Applications/cmux.app/Contents/Resources/bin/cmux"

resolve_cmux_cli() {
  if [[ -n "${CMUX_CLI:-}" ]]; then
    return
  fi
  if [[ -x "$CMUX_APP_CLI" ]]; then
    CMUX_CLI="$CMUX_APP_CLI"
  elif command -v cmux &>/dev/null; then
    CMUX_CLI="cmux"
  else
    CMUX_CLI=""
  fi
}

resolve_cmux_cli

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

require_cmux() {
  if [[ -z "$CMUX_CLI" ]]; then
    echo -e "${RED}cmux CLI not found.${NC}" >&2
    echo "  Expected at: $CMUX_APP_CLI" >&2
    echo "  Install cmux from https://cmux.dev" >&2
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
#
# cmux CLI reference (from cmux help):
#   Global flags: --json, --id-format refs|uuids|both, --socket PATH
#   current-workspace             → returns workspace UUID
#   list-workspaces               → list all workspaces
#   new-workspace                 → create workspace
#   select-workspace --workspace  → switch to workspace
#   list-panes [--workspace]      → list panes in workspace
#   list-pane-surfaces [--pane]   → list surfaces in a pane
#   new-split <dir> [--surface]   → split from a surface
#   focus-pane --pane             → focus a pane
#   send [--surface] <text>       → send text to a surface
#   send-key [--surface] <key>    → send key to a surface
# --------------------------------------------------------------------------

cmux_api() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${YELLOW}cmux $*${NC}" >&2
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] cmux $*" >&2
    return 0
  fi
  "$CMUX_CLI" "$@"
}

cmux_api_json() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "  ${YELLOW}cmux --json --id-format uuids $*${NC}" >&2
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] cmux --json --id-format uuids $*" >&2
    echo "[]"
    return 0
  fi
  "$CMUX_CLI" --json --id-format uuids "$@"
}

cmux_new_workspace() {
  cmux_api new-workspace
}

# Returns the current workspace UUID (plain text, not JSON).
cmux_current_workspace_id() {
  cmux_api current-workspace
}

cmux_list_workspaces() {
  cmux_api_json list-workspaces | jq '.workspaces'
}

cmux_list_panes() {
  local workspace_id="${1:-}"
  if [[ -n "$workspace_id" ]]; then
    cmux_api_json list-panes --workspace "$workspace_id" | jq '.panes'
  else
    cmux_api_json list-panes | jq '.panes'
  fi
}

cmux_list_pane_surfaces() {
  local pane_id="$1"
  cmux_api_json list-pane-surfaces --pane "$pane_id" | jq '.surfaces'
}

cmux_focus_pane() {
  local pane_id="$1"
  cmux_api focus-pane --pane "$pane_id"
}

cmux_new_split() {
  local direction="$1"
  local surface_id="${2:-}"
  if [[ -n "$surface_id" ]]; then
    cmux_api new-split "$direction" --surface "$surface_id"
  else
    cmux_api new-split "$direction"
  fi
}

cmux_send_text() {
  local surface_id="$1"
  local text="$2"
  cmux_api send --surface "$surface_id" "$text"
}

cmux_send_key() {
  local surface_id="$1"
  local key="$2"
  cmux_api send-key --surface "$surface_id" "$key"
}

# Expand {name} and {id} template variables in a string.
expand_template() {
  local template="$1" ws_name="$2" pane_id="$3"
  local result="$template"
  result="${result//\{name\}/$ws_name}"
  result="${result//\{id\}/$pane_id}"
  echo "$result"
}

cmux_send_command() {
  local surface_id="$1"
  local dir="$2"
  local command="$3"

  if [[ -n "$command" ]]; then
    cmux_send_text "$surface_id" "$command"
    cmux_send_key "$surface_id" enter
  fi

  if [[ -n "$dir" ]]; then
    # Wait for command to start (e.g. SSH to connect) before sending cd
    if [[ -n "$command" ]]; then
      sleep 2
    fi
    local expanded_dir="${dir/#\~/$HOME}"
    cmux_send_text "$surface_id" "cd ${expanded_dir}"
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

# Get workspace name: explicit .name field, or derive from config filename.
config_get_name() {
  local json="$1" config_file="${2:-}"
  local name
  name=$(echo "$json" | jq -r '.name // empty')
  if [[ -z "$name" && -n "$config_file" ]]; then
    name=$(basename "$config_file" .yaml)
  fi
  echo "$name"
}

config_get_dir() {
  echo "$1" | jq -r '.dir // empty'
}

config_get_focus() {
  echo "$1" | jq -r '.focus // empty'
}

config_get_pane_count() {
  echo "$1" | jq '.panes | length'
}

# Get a pane field, falling back to the top-level value for "dir".
config_get_pane_field() {
  local json="$1" index="$2" field="$3"
  local value
  value=$(echo "$json" | jq -r ".panes[$index].$field // empty")
  if [[ -z "$value" && "$field" == "dir" ]]; then
    value=$(echo "$json" | jq -r '.dir // empty')
  fi
  echo "$value"
}

# --------------------------------------------------------------------------
# State file I/O
#
# Pane maps store { config_pane_id: { pane: cmux_pane_uuid, surface: cmux_surface_uuid } }
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

state_save_pane_entry() {
  local name="$1" config_pane_id="$2" cmux_pane_id="$3" cmux_surface_id="$4"
  ensure_state_dirs
  local map_file="$CMUX_WS_PANE_MAPS_DIR/${name}.json"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$map_file" ]]; then
    jq --arg key "$config_pane_id" --arg pane "$cmux_pane_id" --arg surface "$cmux_surface_id" \
      '.[$key] = {"pane": $pane, "surface": $surface}' "$map_file" > "$tmp"
  else
    jq -n --arg key "$config_pane_id" --arg pane "$cmux_pane_id" --arg surface "$cmux_surface_id" \
      '{($key): {"pane": $pane, "surface": $surface}}' > "$tmp"
  fi
  mv "$tmp" "$map_file"
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
# Pane ID diffing
# --------------------------------------------------------------------------

# Extract pane UUIDs from list-panes JSON (one per line, sorted).
extract_pane_ids() {
  jq -r '.[].id' | sort
}

# Find pane ID(s) present in "after" but not "before".
# Args: file_before file_after (files with one ID per line, sorted)
find_new_ids() {
  comm -13 "$1" "$2"
}

# Get the first surface UUID for a given pane UUID.
get_first_surface_for_pane() {
  local pane_id="$1"
  cmux_list_pane_surfaces "$pane_id" | jq -r '.[0].id'
}

# --------------------------------------------------------------------------
# Temp-file-based pane map (bash 3 compatible)
#
# Format: config_pane_id<TAB>cmux_pane_id<TAB>cmux_surface_id
# --------------------------------------------------------------------------

pane_map_create() {
  mktemp -t cmux-ws-pane-map.XXXXXX
}

pane_map_set() {
  local map_file="$1" config_id="$2" cmux_pane="$3" cmux_surface="$4"
  printf '%s\t%s\t%s\n' "$config_id" "$cmux_pane" "$cmux_surface" >> "$map_file"
}

pane_map_get_surface() {
  local map_file="$1" config_id="$2"
  awk -F'\t' -v id="$config_id" '$1 == id { print $3 }' "$map_file" | tail -1
}

pane_map_get_pane() {
  local map_file="$1" config_id="$2"
  awk -F'\t' -v id="$config_id" '$1 == id { print $2 }' "$map_file" | tail -1
}
