#!/usr/bin/env bash
# p10k-style statusline for Claude Code
# Mirrors ~/.p10k.zsh: os_icon | dir | vcs segments with powerline separators

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')

# 256-color helpers
fg() { printf '\033[38;5;%dm' "$1"; }
bg() { printf '\033[48;5;%dm' "$1"; }
reset() { printf '\033[0m'; }
bold() { printf '\033[1m'; }

# p10k colors from ~/.p10k.zsh
BG=234        # segment background (POWERLEVEL9K_BACKGROUND)
OS_FG=255     # os_icon foreground
DIR_FG=31     # directory foreground
DIR_ANCHOR=39 # directory anchor (last component) foreground
VCS_CLEAN=76  # git clean
META=244      # grey meta text

# Powerline glyphs
SEP=$'\uE0B0'       #
SEP_START=$'\uE0B6'  #
SUBSEP=$'\uE0B1'     #
BRANCH=$'\uF126'     #

# --- OS icon segment ---
os_icon=""

# --- Directory segment (shorten like p10k) ---
# Replace $HOME with ~
dir="${cwd/#$HOME/\~}"

# Split into components - show last component bold in anchor color
if [[ "$dir" == */* ]]; then
  parent="${dir%/*}/"
  anchor="${dir##*/}"
else
  parent=""
  anchor="$dir"
fi

# --- Git segment (lock-free: reads HEAD directly from filesystem) ---
git_info=""
git_dir=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
if [[ -n "$git_dir" ]]; then
  # Read branch from HEAD file directly — no index lock needed
  head_content=$(cat "$git_dir/HEAD" 2>/dev/null)
  if [[ "$head_content" == ref:* ]]; then
    branch="${head_content#ref: refs/heads/}"
  else
    # Detached HEAD
    branch="@${head_content:0:7}"
  fi

  # Truncate long branch names (first 12...last 12)
  if (( ${#branch} > 32 )); then
    branch="${branch:0:12}…${branch: -12}"
  fi

  git_info="$(fg $VCS_CLEAN)${BRANCH} ${branch}"
fi

# --- Render segments ---
output=""

# Start cap
output+="$(fg $BG)${SEP_START}"

# OS icon segment
output+="$(bg $BG)$(fg $OS_FG) ${os_icon} "

# Separator (same bg, just a thin divider)
output+="$(fg $META)${SUBSEP} "

# Dir segment
if [[ -n "$parent" ]]; then
  output+="$(fg $DIR_FG)${parent}$(bold)$(fg $DIR_ANCHOR)${anchor}"
else
  output+="$(bold)$(fg $DIR_ANCHOR)${anchor}"
fi

# Git segment (if available)
if [[ -n "$git_info" ]]; then
  output+=" $(fg $META)${SUBSEP} ${git_info}"
fi

# End cap
output+=" $(reset)$(fg $BG)${SEP}$(reset)"

printf '%s' "$output"
