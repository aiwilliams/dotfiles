# Powerlevel10k instant prompt (must stay near top of .zshrc)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# --- Oh My Zsh ---

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zmx zsh-autosuggestions zsh-syntax-highlighting)
source "$ZSH/oh-my-zsh.sh"

# --- Environment ---

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$HOME/.local/bin:$PNPM_HOME:$PATH"
export NX_TUI=false

# --- Aliases & Functions ---

# Neovim v0.11+ sends a DA1 query (\e[c) during its exit cleanup, just before
# leaving the alternate screen. Over SSH, the round-trip to Ghostty means the
# response (\e[?62;22;52c) arrives after neovim has exited, so it leaks to the
# shell prompt as "62;22;52c". Wrapping nvim in a function that briefly drains
# stdin after exit catches these stale terminal responses. The 50ms timeout
# covers typical SSH round-trip latency; on a local terminal the drain is
# near-instant. Type-ahead is not a concern here since users don't pre-type
# commands while still inside vim.
vim() {
  command nvim "$@"
  local _byte
  while read -t 0.05 -k 1 _byte 2>/dev/null; do :; done
}

# Wrap wt so that `wt switch` can cd in the current shell
wt() {
  case "${1:-}" in
    switch|main)
      local dir
      dir=$(command wt "$@") || return
      [[ -n "$dir" ]] && cd "$dir"
      ;;
    create|checkout)
      rm -f /tmp/wt_cd_path
      command wt "$@" || return
      [[ -f /tmp/wt_cd_path ]] && cd "$(</tmp/wt_cd_path)" && rm -f /tmp/wt_cd_path
      ;;
    *)
      command wt "$@"
      ;;
  esac
}

# Launch claude inside a per-invocation systemd user scope on Linux so
# systemd-oomd kills only this session's scope, never the SSH login
# session it was launched from. On any other OS — or anywhere the `scope`
# helper / systemd-run is unavailable — this is a transparent pass-through.
#
# Without the wrap, claude inherits the SSH login session's cgroup
# (session-cNNN.scope). Under SwapUsedLimit pressure, oomd ranks
# descendants of user-NNNN.slice by swap usage and kills the worst scope
# wholesale, taking the SSH connection down with claude. Wrapped, claude
# runs in user@.service/app.slice/scope-claude-PID.scope — a sibling of
# the session scope — so oomd picks the heavier claude scope and the SSH
# session survives, prompt returning in the same TTY. The named scope is
# also self-identifying in oomctl, systemd-cgtop, and oomd kill logs.
#
# Memory posture (override any of these via the environment):
#   CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (default 60) — compact the in-memory
#     transcript at this % of the context window instead of the ~95%
#     default. The 1M Opus window otherwise lets the node heap grow huge
#     before its first compaction; lower trades more frequent summarization
#     for a smaller resident heap. The CLI only honours values that LOWER
#     the threshold.
#   CLAUDE_SCOPE_SWAP_MAX (unset → no per-scope cap) — MemorySwapMax per scope.
#     Left uncapped so the kernel can offload claude's cold (anonymous) heap
#     pages to swap under pressure, shrinking its resident set and lowering the
#     reclaim activity that a systemd-oomd *pressure* kill ranks victims on. An
#     earlier 512M cap pinned that heap in RAM (anon pages have nowhere to go
#     but swap), which inflated claude's pressure signature and made it the
#     pressure-kill victim — every observed kill was pressure-based. The swap-hog
#     protection the cap was meant to provide (not being oomd's swap-kill target)
#     now comes directly from ManagedOOMPreference=avoid below, which covers both
#     swap and pressure kills. Set e.g. 4G only if several concurrent sessions
#     start filling the small system swap and provoking collateral swap-kills.
#   CLAUDE_SCOPE_MEMORY_HIGH (default 32G) — MemoryHigh per scope. Soft
#     throttle: the kernel reclaims and slows allocations past this but
#     never kills.
#   CLAUDE_SCOPE_MEMORY_MAX (unset) — MemoryMax per scope. Left unset so an
#     active session is never hard-killed; set it (e.g. 40G) only to add a
#     kernel backstop against a pathological runaway.
#   CLAUDE_OOMD_PREFERENCE (default avoid) — ManagedOOMPreference on the scope.
#     systemd-oomd ignores earlyoom's name lists and a *pressure* kill targets
#     the heaviest-reclaim cgroup, which is usually this interactive session
#     rather than a larger idle dev server. "avoid" demotes claude below
#     un-marked sibling scopes so a dev server / build is killed first; "omit"
#     makes claude entirely ineligible (it thrashes instead — relies on the
#     MemoryMax/earlyoom/kernel backstop); "none" opts out.
#
# A function is used rather than a PATH-prepended wrapper script because
# `mise activate zsh` (sourced below) restores PATH from a captured
# snapshot on every shell re-init, dropping any prepends made in .zshenv.
# Functions take precedence over PATH lookup in all shell contexts, so
# this survives `omz reload` and re-execs cleanly.
claude() {
  local bin
  bin=$(whence -p claude) || { print -u2 "claude: command not found"; return 127 }

  # local -x: exported to the launched process for this call only, so it
  # does not linger in the interactive shell after claude exits.
  local -x CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-60}"

  if [[ "$(uname -s)" != Linux ]] || ! command -v scope >/dev/null 2>&1; then
    "$bin" "$@"
    return
  fi

  local -a caps=(
    --name=claude
    "--high=${CLAUDE_SCOPE_MEMORY_HIGH:-32G}"
  )
  case "${CLAUDE_OOMD_PREFERENCE:-avoid}" in
    avoid) caps+=(--oom-avoid) ;;
    omit)  caps+=(--oom-omit) ;;
  esac
  [[ -n "${CLAUDE_SCOPE_SWAP_MAX:-}" ]] && caps+=("--swap-max=${CLAUDE_SCOPE_SWAP_MAX}")
  [[ -n "${CLAUDE_SCOPE_MEMORY_MAX:-}" ]] && caps+=("--max=${CLAUDE_SCOPE_MEMORY_MAX}")
  scope "${caps[@]}" -- "$bin" "$@"
}

# --- Platform-specific ---

case "$(uname -s)" in
  Linux)
    # pbcopy via OSC 52 (works over SSH + tmux)
    alias pbcopy='printf "\033]52;c;%s\a" "$(base64)"'
    # SSH key via keychain
    eval "$(keychain --eval --quiet --agents ssh id_ed25519_$(hostname))"
    ;;
esac

# --- Terminal fixups ---

# TUI programs (Claude Code, neovim) may push the kitty keyboard protocol
# and/or enable xterm modifyOtherKeys without properly restoring on exit,
# leaving Ctrl-C, Ctrl-R, etc. emitting raw CSI u sequences. Pop up to 99
# kitty protocol stack entries and reset modifyOtherKeys before each prompt.
_reset_keyboard_protocol() { printf '\e[<99u\e[>4;0m' >/dev/tty; }
precmd_functions+=(_reset_keyboard_protocol)

# --- Tools ---

eval "$(mise activate zsh)"

# --- Local overrides (not version-controlled) ---

[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

# Powerlevel10k config (generated by `p10k configure`)
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
