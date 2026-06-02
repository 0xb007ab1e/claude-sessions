#!/usr/bin/env bash
# tests/watchdog.sh — exercises claude-watchdog's decisions with a FAKE tmux
# (logs commands, pretends the window exists), an isolated HOME/state, and a
# seeded registry. No real tmux/panes needed. Asserts:
#   clean exit (status 0)  -> kill-window (close the lingering dead pane)
#   crash (status != 0)    -> respawn-pane with the resume command
#   crash loop > max        -> give up (no respawn)
#   intentional close (row not active / window gone) -> no-op
set -eo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_STATE_HOME="$WORK/state" CLAUDE_TMUX_SESSION="_wd"
export CJ_CLAUDE="claude"                     # literal, just goes into the logged command
mkdir -p "$HOME/.config/claude-sessions"
cat > "$HOME/.config/claude-sessions/config" <<EOF
watchdog = true
watchdog_restart_on = crash
watchdog_max_retries = 2
watchdog_window = 600
watchdog_backoff = 0
notify = none
EOF

# Fake tmux: log every call; list-panes succeeds (window "exists").
mkdir -p "$WORK/bin"; export TMUX_LOG="$WORK/tmux.log"; : > "$TMUX_LOG"
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMUX_LOG"
[ "$1" = list-panes ] && exit 0
exit 0
EOF
chmod +x "$WORK/bin/tmux"; export PATH="$WORK/bin:$PATH"

# Seed one active instance (transcript + model/effort).
( source "$REPO/lib.sh"; cs_record_active alpha 39 @5 /home/u/proj uuid-123 opus high )

rc=0
WD="$REPO/claude-watchdog"

# 1) clean exit -> kill-window
: > "$TMUX_LOG"; "$WD" @5 0
grep -q "kill-window -t _wd:@5" "$TMUX_LOG" \
  && echo "PASS [clean exit -> kill-window]" || { echo "FAIL [clean exit]"; cat "$TMUX_LOG"; rc=1; }

# 2) crash -> respawn-pane with the resume command (model/effort included)
rm -rf "$XDG_STATE_HOME/claude-sessions/watchdog"; : > "$TMUX_LOG"; "$WD" @5 1
if grep -q "respawn-pane -t _wd:@5 -c /home/u/proj exec claude --resume uuid-123 --model opus --effort high" "$TMUX_LOG"; then
  echo "PASS [crash -> respawn with resume+model+effort]"
else echo "FAIL [crash respawn]"; cat "$TMUX_LOG"; rc=1; fi

# 3) crash loop: max_retries=2 -> calls 1,2 respawn; call 3 gives up (no respawn)
rm -rf "$XDG_STATE_HOME/claude-sessions/watchdog"
n_respawn=0
for i in 1 2 3; do
  : > "$TMUX_LOG"; "$WD" @5 1
  grep -q "respawn-pane" "$TMUX_LOG" && n_respawn=$((n_respawn+1))
done
[ "$n_respawn" -eq 2 ] \
  && echo "PASS [crash loop -> 2 respawns then give up]" || { echo "FAIL [give-up]: respawns=$n_respawn (want 2)"; rc=1; }

# 4) not a managed/active instance -> no-op (no tmux mutations)
rm -rf "$XDG_STATE_HOME/claude-sessions/watchdog"; : > "$TMUX_LOG"; "$WD" @999 1
if grep -qE "respawn-pane|kill-window" "$TMUX_LOG"; then echo "FAIL [unmanaged window acted on]"; rc=1
else echo "PASS [unmanaged window -> no-op]"; fi

exit $rc
