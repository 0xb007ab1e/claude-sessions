#!/usr/bin/env bash
# tests/reload.sh — exercises claude-reload with a FAKE tmux (logs commands,
# fakes has-session/display-message), an isolated HOME/state, and a seeded
# registry. No real tmux/panes needed. Asserts:
#   -n NAME (other window)  -> respawn-pane -k with the resume command, immediately
#   current window (self)   -> deferred: a run-shell -b carrying the respawn+resume
#   unknown name            -> error, no respawn
#   ephemeral shell         -> refused, no respawn
#   no linked transcript    -> relink from the *.jsonl and resume it exactly
set -eo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_STATE_HOME="$WORK/state" CLAUDE_TMUX_SESSION="_rl"
export CJ_CLAUDE="claude"                      # literal, just goes into the logged command
mkdir -p "$HOME/.config/claude-sessions"
echo "notify = none" > "$HOME/.config/claude-sessions/config"

# Fake tmux: log every call; has-session/list-panes succeed; display-message
# resolves the "current" window to @5 (the seeded alpha instance).
mkdir -p "$WORK/bin"; export TMUX_LOG="$WORK/tmux.log"; : > "$TMUX_LOG"
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMUX_LOG"
case "$1" in
  has-session|list-panes|respawn-pane|run-shell) exit 0 ;;
  display-message) echo "@5"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/tmux"; export PATH="$WORK/bin:$PATH"

# Seed: one active instance (alpha @5, transcript uuid-123, opus/high) and one
# ephemeral shell (sh1 @7).
( source "$REPO/lib.sh"
  cs_record_active alpha 39 @5 /home/u/proj uuid-123 opus high
  cs_record_active sh1   41 @7 /home/u/s   ""        ""   ""   shell @5 )

rc=0
RL="$REPO/claude-reload"

# 1) -n alpha (an explicit, non-current window) -> immediate respawn-pane -k w/ resume
: > "$TMUX_LOG"; unset TMUX_PANE
"$RL" -n alpha >/dev/null 2>&1 || true
if grep -q "respawn-pane -k -t _rl:@5 -c /home/u/proj exec claude --resume uuid-123 --model opus --effort high" "$TMUX_LOG"; then
  echo "PASS [-n -> immediate respawn with resume+model+effort]"
else echo "FAIL [-n respawn]"; cat "$TMUX_LOG"; rc=1; fi

# 2) current window (self, no -n) -> DEFERRED: a run-shell carrying the respawn+resume
: > "$TMUX_LOG"
"$RL" >/dev/null 2>&1 || true
if grep -q "run-shell" "$TMUX_LOG" && grep -q "respawn-pane -k" "$TMUX_LOG" && grep -q "uuid-123" "$TMUX_LOG"; then
  echo "PASS [self -> deferred run-shell respawn]"
else echo "FAIL [self deferred]"; cat "$TMUX_LOG"; rc=1; fi
# and it must NOT respawn the pane synchronously (only via the deferred run-shell)
if grep -qE "^respawn-pane -k -t _rl:@5" "$TMUX_LOG"; then
  echo "FAIL [self respawned synchronously]"; rc=1
else echo "PASS [self did not respawn synchronously]"; fi

# 3) unknown name -> error, no respawn
: > "$TMUX_LOG"
if "$RL" -n __nope__ >/dev/null 2>&1; then echo "FAIL [unknown name exited 0]"; rc=1
else grep -q "respawn-pane" "$TMUX_LOG" && { echo "FAIL [unknown name respawned]"; rc=1; } || echo "PASS [unknown name -> error, no respawn]"; fi

# 4) ephemeral shell -> refused, no respawn
: > "$TMUX_LOG"
if "$RL" -n sh1 >/dev/null 2>&1; then echo "FAIL [shell reloaded (exit 0)]"; rc=1
else grep -q "respawn-pane" "$TMUX_LOG" && { echo "FAIL [shell respawned]"; rc=1; } || echo "PASS [ephemeral shell -> refused]"; fi

# 5) no linked transcript but a *.jsonl exists -> relink + resume exact
export CLAUDE_CONFIG_DIR="$WORK/cc"
projB="$WORK/projB"; mkdir -p "$projB"
enc="$(printf '%s' "$projB" | sed 's#[^A-Za-z0-9]#-#g')"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$enc"; : > "$CLAUDE_CONFIG_DIR/projects/$enc/relinked-uuid.jsonl"
( source "$REPO/lib.sh"; cs_record_active beta 40 @6 "$projB" "" "" "" )   # empty transcript
: > "$TMUX_LOG"
"$RL" -n beta >/dev/null 2>&1 || true
if grep -q "respawn-pane -k -t _rl:@6 -c $projB exec claude --resume relinked-uuid" "$TMUX_LOG"; then
  echo "PASS [no transcript -> relinked + resume exact]"
else echo "FAIL [relink]"; cat "$TMUX_LOG"; rc=1; fi

# 6) SECURITY regression (review #1, CWE-78): a hostile transcript basename must
# reach the respawn command SHELL-QUOTED, so the sh -c that tmux runs can't
# execute an injected `;`-separated command. Assert the %q-escaped form is present
# and the bare injection (`; touch`) is NOT.
unset CLAUDE_CONFIG_DIR
PAYLOAD='u;touch /tmp/pwn'
( source "$REPO/lib.sh"; cs_record_active evil 42 @8 /home/u/evil "$PAYLOAD" opus high )
: > "$TMUX_LOG"
"$RL" -n evil >/dev/null 2>&1 || true
Q="$(printf %q "$PAYLOAD")"
if grep -qF -- "--resume $Q" "$TMUX_LOG" && ! grep -qF -- '--resume u;touch' "$TMUX_LOG"; then
  echo "PASS [hostile transcript -> shell-quoted, no injection]"
else echo "FAIL [injection quoting]"; cat "$TMUX_LOG"; rc=1; fi

exit $rc
