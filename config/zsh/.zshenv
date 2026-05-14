export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

export PATH="$HOME/.local/bin:$PATH"

# Pin zmx socket directory so sessions are visible across all shells regardless
# of whether XDG_RUNTIME_DIR is set. Without this, SSH ControlMaster-multiplexed
# shells (which skip PAM and so lack XDG_RUNTIME_DIR) and fresh PAM shells land
# in different buckets and can't see each other's sessions.
export ZMX_DIR="/tmp/zmx-${UID:-$(id -u)}"

# Reset OOM score so child processes (node, tsgo, etc.) are killable by
# earlyoom. SSH and Tailscale SSH sessions inherit -900 OOMScoreAdjust from
# sshd/tailscaled, making every child process nearly immune to the OOM killer.
# This must be in .zshenv (not .zshrc) to cover non-interactive commands too
# (e.g. ssh fw 'node build.js').
if [[ "$(uname -s)" == Linux ]] && (( $(</proc/self/oom_score_adj) < 0 )) 2>/dev/null; then
  echo 0 > /proc/self/oom_score_adj
fi

# Machine-local overrides (secrets, NGROK_DOMAIN, etc.) — not checked into git.
[[ -f ~/.zshenv.local ]] && source ~/.zshenv.local
