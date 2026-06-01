#!/usr/bin/env bash
# tests/integration.sh — end-to-end test of the interactive directory picker.
#
# Drives the real fzf picker (the one behind "New in dir…" / prefix+D) by
# running `claude-new -D` in a real tmux pane and feeding keystrokes with
# `tmux send-keys` — the reliable way to exercise a full-screen TUI headlessly
# (piping into /dev/tty or puppeting a display-popup is not). Then asserts that
# a new instance window opened in the picked directory.
#
# Fully isolated: a private tmux socket (-L, never touches your real server), a
# temp $HOME/state, fixture project dirs, and a stub `claude`. Skips cleanly
# (exit 0) when tmux or fzf is unavailable, so it's safe in minimal CI.
#
#   bash tests/integration.sh
set -eo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
command -v fzf  >/dev/null 2>&1 || { echo "SKIP: fzf not installed (no typeahead to test)"; exit 0; }

WORK="$(mktemp -d)"
SOCK="csint$$"
SESSION="csint$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Isolated environment + fixtures.
export HOME="$WORK/home"
export XDG_STATE_HOME="$WORK/state"
export CLAUDE_TMUX_SESSION="$SESSION"
mkdir -p "$HOME/.config/claude-sessions" "$WORK/proj/mail-bot" "$WORK/proj/web-app" "$WORK/proj/docs-site"
printf 'search_dir = %s\n' "$WORK/proj" > "$HOME/.config/claude-sessions/config"

# Stub `claude` so no real CLI launches; the window just runs `sleep`.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec sleep 30\n' > "$WORK/bin/claude"; chmod +x "$WORK/bin/claude"
export CJ_CLAUDE="$WORK/bin/claude"

TM="tmux -L $SOCK -f $REPO/tmux.conf"   # private socket
$TM new-session -d -s "$SESSION" -x 120 -y 40

# Run the picker in a real pane; its bare `tmux` calls inherit $TMUX = our socket.
launch="$($TM new-window -t "$SESSION:" -P -F '#{window_id}' \
  "CJ_CLAUDE='$CJ_CLAUDE' CLAUDE_TMUX_SESSION='$SESSION' XDG_STATE_HOME='$XDG_STATE_HOME' HOME='$HOME' '$REPO/claude-new' -D")"

sleep 2                                  # let fzf load the candidate list
$TM send-keys -t "$launch" C-u           # clear the prefilled query
$TM send-keys -t "$launch" -l 'mail-bot' # type the query
sleep 1                                  # let fzf filter
$TM send-keys -t "$launch" Enter         # select the top match
sleep 2                                  # let claude-new open the window

want="$WORK/proj/mail-bot"
if $TM list-windows -t "$SESSION" -F '#{pane_current_path}' 2>/dev/null | grep -qx "$want"; then
  echo "PASS: picker opened an instance in $want"
  exit 0
fi
echo "FAIL: expected a window in $want; got:"
$TM list-windows -t "$SESSION" -F '  #I:#W #{pane_current_path}' 2>/dev/null
exit 1
