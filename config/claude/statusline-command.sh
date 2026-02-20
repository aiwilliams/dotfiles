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
VCS_MOD=178   # git modified
VCS_UNTRACKED=39  # git untracked
VCS_CONFLICT=196  # git conflicted
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

# --- Git segment ---
git_info=""
if git -C "$cwd" rev-parse --git-dir &>/dev/null; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  if [[ -z "$branch" ]]; then
    # Detached HEAD - show short commit
    branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    branch="@${branch}"
  fi

  # Truncate long branch names (first 12...last 12)
  if (( ${#branch} > 32 )); then
    branch="${branch:0:12}…${branch: -12}"
  fi

  # Get status counts
  staged=0 unstaged=0 untracked=0 conflicted=0
  while IFS= read -r line; do
    x="${line:0:1}" y="${line:1:1}"
    case "$x$y" in
      "##"|"!!") ;;
      *U*|AA|DD) ((conflicted++)) ;;
      *)
        [[ "$x" != " " && "$x" != "?" ]] && ((staged++))
        [[ "$y" != " " && "$y" != "?" ]] && ((unstaged++))
        [[ "$x" == "?" ]] && ((untracked++))
        ;;
    esac
  done < <(git -C "$cwd" status --porcelain=v1 2>/dev/null)

  # Ahead/behind
  ahead=0 behind=0
  read -r ahead behind < <(git -C "$cwd" rev-list --left-right --count "HEAD...@{upstream}" 2>/dev/null || echo "0 0")

  # Choose color based on state
  if (( conflicted > 0 )); then
    vcs_fg=$VCS_CONFLICT
  elif (( staged > 0 || unstaged > 0 )); then
    vcs_fg=$VCS_MOD
  else
    vcs_fg=$VCS_CLEAN
  fi

  # Build git string
  git_info="$(fg $vcs_fg)${BRANCH} ${branch}"

  # Behind/ahead
  (( behind > 0 )) && git_info+=" $(fg $VCS_CLEAN)⇣${behind}"
  (( ahead > 0 )) && git_info+=" $(fg $VCS_CLEAN)⇡${ahead}"

  # Staged/unstaged/untracked/conflicted
  (( conflicted > 0 )) && git_info+=" $(fg $VCS_CONFLICT)~${conflicted}"
  (( staged > 0 )) && git_info+=" $(fg $VCS_MOD)+${staged}"
  (( unstaged > 0 )) && git_info+=" $(fg $VCS_MOD)!${unstaged}"
  (( untracked > 0 )) && git_info+=" $(fg $VCS_UNTRACKED)?${untracked}"
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
