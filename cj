#!/usr/bin/env bash
# cj — "claude-join": attach to the persistent, statically-named tmux session
# and land in a running Claude instance.
#
# Behaviour (from a normal shell):
#   * ensure the `claude` session exists (the systemd user service normally
#     starts it at boot; this is a fallback if it isn't up yet),
#   * REUSE an idle shell window by launching Claude in it, or if every window
#     already has Claude running, open a NEW window with a fresh instance,
#   * attach you to the session.
# Inside tmux already, it just runs the real Claude CLI in the current pane.
#
# It deliberately does NOT shadow `claude` — run `cj` (or click the desktop
# shortcut) to join; run `claude` for a plain, non-tmux instance.

set -euo pipefail

S=claude
CONF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/tmux.conf"
REAL_CLAUDE="${CJ_CLAUDE:-$HOME/.local/bin/claude}"
T=(tmux -f "$CONF")

# Already inside tmux: just run the real CLI here (no nesting).
if [ -n "${TMUX:-}" ]; then
  exec "$REAL_CLAUDE" "$@"
fi

# Make sure the session exists (fallback if the boot service hasn't run).
if ! "${T[@]}" has-session -t "$S" 2>/dev/null; then
  "${T[@]}" new-session -d -s "$S"
fi

# Find an idle window whose active pane is a plain shell.
idle="$("${T[@]}" list-windows -t "$S" \
          -F '#{window_index} #{pane_current_command}' \
        | awk '$2 ~ /^(bash|zsh|sh|fish|-bash)$/ {print $1; exit}')"

if [ -n "$idle" ]; then
  # Reuse it: exec so the window closes cleanly when Claude exits.
  "${T[@]}" send-keys -t "$S:$idle" "exec $REAL_CLAUDE $*" C-m
  "${T[@]}" select-window -t "$S:$idle"
else
  # All windows busy: spin up a fresh instance in a new window.
  "${T[@]}" new-window -t "$S" "exec $REAL_CLAUDE $*"
fi

exec "${T[@]}" attach -t "$S"
