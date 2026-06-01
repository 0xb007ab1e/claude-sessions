#!/usr/bin/env bash
# tests/integration.sh — end-to-end tests of the directory picker and the popup
# layer behind "New in dir…" / prefix+D.
#
# Two checks (full-screen TUIs can't be driven by piping to /dev/tty, so we run
# them in real tmux contexts and use tmux to deliver input / launch them):
#   1) PANE PICKER  — run `claude-new -D` in a real pane, drive fzf with
#      `tmux send-keys`, assert a window opens in the picked directory.
#   2) POPUP EXEC   — attach a client and run `claude-new` via `display-popup`
#      (the same container prefix+D uses), assert it opens a window. Best-effort:
#      SKIPs if a headless client can't be attached.
#
# Fully isolated: a private tmux socket (-L; never touches your real server), a
# temp $HOME/state, fixture project dirs, and a stub `claude`. The whole script
# SKIPs (exit 0) when tmux or fzf is unavailable, so it's safe in minimal CI.
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

export HOME="$WORK/home"
export XDG_STATE_HOME="$WORK/state"
export CLAUDE_TMUX_SESSION="$SESSION"
mkdir -p "$HOME/.config/claude-sessions" "$WORK/proj/mail-bot" "$WORK/proj/web-app" "$WORK/proj/docs-site"
printf 'search_dir = %s\n' "$WORK/proj" > "$HOME/.config/claude-sessions/config"

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec sleep 30\n' > "$WORK/bin/claude"; chmod +x "$WORK/bin/claude"
export CJ_CLAUDE="$WORK/bin/claude"

TM="tmux -L $SOCK -f $REPO/tmux.conf"   # private socket
ENVPREFIX="CJ_CLAUDE='$CJ_CLAUDE' CLAUDE_TMUX_SESSION='$SESSION' XDG_STATE_HOME='$XDG_STATE_HOME' HOME='$HOME'"
$TM new-session -d -s "$SESSION" -x 120 -y 40

opened_in() { $TM list-windows -t "$SESSION" -F '#{pane_current_path}' 2>/dev/null | grep -qx "$1"; }

rc=0

# ── 1) PANE PICKER ───────────────────────────────────────────────────────────
launch="$($TM new-window -t "$SESSION:" -P -F '#{window_id}' "$ENVPREFIX '$REPO/claude-new' -D")"
sleep 2
$TM send-keys -t "$launch" C-u
$TM send-keys -t "$launch" -l 'mail-bot'
sleep 1
$TM send-keys -t "$launch" Enter
sleep 2
if opened_in "$WORK/proj/mail-bot"; then
  echo "PASS [pane picker]: fzf selection opened an instance in proj/mail-bot"
else
  echo "FAIL [pane picker]: no window in $WORK/proj/mail-bot"; rc=1
fi

# ── 2) POPUP EXEC (best-effort) ──────────────────────────────────────────────
# Keep a pty's stdin open for ~10s so the headless client stays attached.
( sleep 10 ) | script -qec "$TM attach -t $SESSION" /dev/null >/dev/null 2>&1 &
spid=$!
client=""
for _ in $(seq 1 20); do
  client="$($TM list-clients -F '#{client_name}' 2>/dev/null | head -1)"
  [ -n "$client" ] && break; sleep 0.3
done
if [ -n "$client" ]; then
  $TM display-popup -c "$client" -E "$ENVPREFIX '$REPO/claude-new' -c '$WORK/proj/web-app' -n poptest" 2>/dev/null || true
  sleep 1
  if opened_in "$WORK/proj/web-app"; then
    echo "PASS [popup exec]: display-popup ran claude-new; instance opened in proj/web-app"
  else
    echo "FAIL [popup exec]: no window in $WORK/proj/web-app"; rc=1
  fi
else
  echo "SKIP [popup exec]: could not attach a headless client (need a pty / 'script')"
fi
kill "$spid" 2>/dev/null || true

exit $rc
