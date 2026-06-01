#!/usr/bin/env bash
# cj — "claude-join": attach to the persistent, statically-named tmux session
# and land in a running Claude instance.
#
# Usage: cj [-a [scheme]] [-n name] [-M model] [-E effort] [-- claude-args…]
#   -a [scheme]  auto-name the instance (and color it) using scheme
#                nato|project|random (default: config/$CLAUDE_NAME_SCHEME/nato);
#                also default-on if config has `auto_name = true`
#   -n name      give the instance an explicit name (implies naming)
#   -M model     model for this instance: alias (sonnet|opus|haiku) or full id
#   -E effort    effort for this instance: low | medium | high | xhigh | max
#
# Behaviour (from a normal shell):
#   * ensure the session exists (the systemd user service normally starts it at
#     boot; this is a fallback),
#   * REUSE an idle shell window for a fresh Claude, else open a NEW window,
#   * optionally name + color + register the instance, then attach.
# Inside tmux already, it just runs the real Claude CLI in the current pane.
#
# It deliberately does NOT shadow `claude` — run `cj` to join; run `claude` for
# a plain, non-tmux instance.

set -eo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$HERE/lib.sh"

S="$(cs_session)"
CONF="$HERE/tmux.conf"
REAL_CLAUDE="${CJ_CLAUDE:-$(command -v claude 2>/dev/null || true)}"
REAL_CLAUDE="${REAL_CLAUDE:-$HOME/.local/bin/claude}"
T=(tmux -f "$CONF")

AUTONAME=0 SCHEME="" NAME="" MODEL="" EFFORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--auto) AUTONAME=1; shift
               case "${1:-}" in nato|project|random) SCHEME="$1"; shift ;; esac ;;
    -n|--name)   NAME="${2:-}"; AUTONAME=1; shift 2 ;;
    -M|--model)  MODEL="${2:-}"; shift 2 ;;
    -E|--effort) EFFORT="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    -*)        echo "cj: unknown option $1" >&2; exit 1 ;;
    *)         break ;;
  esac
done
# Config can make auto-naming the default.
[ "$AUTONAME" -eq 0 ] && [ "$(cs_config_get auto_name false)" = "true" ] && AUTONAME=1

# Per-instance model/effort: flag, else configured default. Prepend to the args
# passed through to the real Claude CLI (so they apply on every launch path).
MODEL="${MODEL:-$(cs_config_get default_model "")}"
EFFORT="${EFFORT:-$(cs_config_get default_effort "")}"
if [ -n "$EFFORT" ] && ! printf '%s' "$EFFORT" | grep -qxE 'low|medium|high|xhigh|max'; then
  echo "cj: ignoring invalid effort '$EFFORT' (use low|medium|high|xhigh|max)" >&2
  EFFORT=""
fi
EXTRA=()
[ -n "$MODEL" ]  && EXTRA+=(--model "$MODEL")
[ -n "$EFFORT" ] && EXTRA+=(--effort "$EFFORT")
set -- "${EXTRA[@]}" "$@"

# Already inside tmux: just run the real CLI here (no nesting).
if [ -n "${TMUX:-}" ]; then
  exec "$REAL_CLAUDE" "$@"
fi

# Ensure the session exists (fallback if the boot service hasn't run).
"${T[@]}" has-session -t "$S" 2>/dev/null || "${T[@]}" new-session -d -s "$S"

# Reuse an idle shell window, else open a new one. Track the window id either way.
idle="$("${T[@]}" list-windows -t "$S" -F '#{window_index} #{pane_current_command}' \
        | awk '$2 ~ /^(bash|zsh|sh|fish|-bash)$/ {print $1; exit}')"
if [ -n "$idle" ]; then
  wid="$("${T[@]}" display-message -t "$S:$idle" -p '#{window_id}')"
  "${T[@]}" send-keys -t "$S:$idle" "exec $REAL_CLAUDE $*" C-m
else
  wid="$("${T[@]}" new-window -t "$S:" -P -F '#{window_id}' "exec $REAL_CLAUDE $*")"
fi

if [ "$AUTONAME" -eq 1 ]; then
  if [ -n "$NAME" ]; then
    name="$NAME"; color="$(cs_color_hash "$NAME")"
  else
    pair="$(cs_alloc_name "$(cs_scheme "$SCHEME")" "$PWD")"
    name="${pair%%$'\t'*}"; color="${pair##*$'\t'}"
  fi
  cs_apply_window "$S:$wid" "$name" "$color"
  cs_record_active "$name" "$color" "$wid" "$PWD" "" "$MODEL" "$EFFORT"
fi

"${T[@]}" select-window -t "$S:$wid"
exec "${T[@]}" attach -t "$S"
