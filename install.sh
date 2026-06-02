#!/usr/bin/env bash
# install.sh — wire this repo into the current user's environment.
#
# Portable & idempotent: makes no assumptions about user, paths, host, or
# desktop. It resolves its own checkout location, finds tmux and a terminal
# emulator, and fills the unit/desktop templates accordingly. Safe to re-run.
#
#   ./install.sh                 # install + enable boot autostart
#   ./install.sh --no-boot       # install shortcuts/config, skip the service
#
# Honors:
#   CLAUDE_TMUX_SESSION   session name (default: claude)
#   TERMINAL              preferred terminal emulator for the desktop shortcut
#
# Uninstall: see README.md.

set -eo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
ENABLE_BOOT=1
[ "${1:-}" = "--no-boot" ] && ENABLE_BOOT=0

# Required dependencies.
TMUX_BIN="$(command -v tmux || true)"
[ -n "$TMUX_BIN" ] || { echo "error: tmux not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || {
  echo "error: jq not found on PATH — required for the instance registry." >&2
  echo "       install it, e.g.:  sudo apt-get install -y jq   (or: brew install jq)" >&2
  exit 1
}

CSCONF="$HOME/.config/claude-sessions"          # fixed: tmux source-file reads ~/.config
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sessions"
mkdir -p "$BIN" "$APPS" "$UNITDIR" "$CSCONF" "$STATE"

# 1. CLI shortcuts on PATH ----------------------------------------------------
for f in cj claude-session claude-ls claude-new claude-restore claude-popup \
         claude-notify claude-snapshot claude-restore-all claude-rename claude-shell \
         claude-pick claude-cd claude-hook claude-status claude-cost claude-model claude-watchdog; do
  ln -sf "$REPO/$f" "$BIN/$f"
  echo "linked   $BIN/$f"
done

# 1c. Claude Code hooks (per-instance status + precise notifications) ---------
# Merge our hook entries into ~/.claude/settings.json (backup first; idempotent
# — replaces any prior claude-hook entries; preserves your other hooks).
csettings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"; [ -f "$csettings" ] || echo '{}' > "$csettings"
if command -v python3 >/dev/null 2>&1; then
  cp "$csettings" "$csettings.cs-bak" 2>/dev/null || true
  CS_HOOK="$BIN/claude-hook" python3 - "$csettings" <<'PY'
import json, os, sys
cfg = sys.argv[1]; hook = os.environ["CS_HOOK"]
try: data = json.load(open(cfg))
except Exception: data = {}
if not isinstance(data, dict): data = {}
hooks = data.setdefault("hooks", {})
for ev in ("SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"):
    lst = [e for e in hooks.get(ev, [])
           if not any("claude-hook" in (h.get("command","")) for h in e.get("hooks", []))]
    lst.append({"matcher":"*","hooks":[{"type":"command","command":f"{hook} {ev}","async":True,"timeout":10}]})
    hooks[ev] = lst
json.dump(data, open(cfg,"w"), indent=2); open(cfg,"a").write("\n")
PY
  echo "wrote    Claude hooks into $csettings (backup: $csettings.cs-bak)"
elif command -v jq >/dev/null 2>&1; then
  cp "$csettings" "$csettings.cs-bak" 2>/dev/null || true
  tmp="$(mktemp)"
  jq --arg c "$BIN/claude-hook" '
    def ours($e): {matcher:"*", hooks:[{type:"command", command:($c+" "+$e), async:true, timeout:10}]};
    .hooks //= {} |
    reduce ("SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd") as $e (.;
      .hooks[$e] = [ (.hooks[$e] // [])[]
                     | select(([.hooks[]?.command // ""] | map(contains("claude-hook")) | any) | not) ]
                   + [ours($e)])
  ' "$csettings" > "$tmp" && mv "$tmp" "$csettings"
  echo "wrote    Claude hooks into $csettings (backup: $csettings.cs-bak)"
else
  echo "skip     Claude hooks (need python3 or jq) — add '$BIN/claude-hook <Event>' hooks to $csettings manually"
fi
echo "note     hooks apply to Claude instances started after install (settings load at launch)"

# 1b. bash completion (sourced from ~/.bashrc, idempotent) --------------------
cline="[ -f $REPO/completions/claude-sessions.bash ] && . $REPO/completions/claude-sessions.bash"
touch "$HOME/.bashrc"
grep -qxF "$cline" "$HOME/.bashrc" || echo "$cline" >> "$HOME/.bashrc"
echo "sourced  bash completion from ~/.bashrc"

# 2. phone-friendly tmux config (sourced from ~/.tmux.conf, idempotent) -------
line="source-file $REPO/tmux.conf"
touch "$HOME/.tmux.conf"
grep -qxF "$line" "$HOME/.tmux.conf" || echo "$line" >> "$HOME/.tmux.conf"
echo "sourced  $REPO/tmux.conf from ~/.tmux.conf"

# 2b. config (don't clobber) + generated key bindings -------------------------
if [ ! -f "$CSCONF/config" ]; then
  cp "$REPO/config.example" "$CSCONF/config"
  echo "wrote    $CSCONF/config (name_scheme=nato)"
else
  echo "kept     $CSCONF/config (already present)"
fi
# If ntfy is the notify backend but no topic is set, prompt for one (interactive
# only); blank auto-generates. Reuses the same logic as `claude-notify --set-topic`.
. "$REPO/lib.sh"
if [ "$(cs_config_get notify desktop)" = ntfy ] && [ -z "$(cs_config_get ntfy_topic '')" ] && [ -t 0 ]; then
  printf 'ntfy topic/slug (blank = auto-generate): '; read -r _topic || _topic=""
  "$REPO/claude-notify" --set-topic "$_topic" | sed 's/^/  /'
fi
sed "s#@BIN@#$BIN#g" "$REPO/tmux/bindings.conf.in" > "$CSCONF/bindings.conf"
echo "wrote    $CSCONF/bindings.conf (tmux menu + keys)"
# Watchdog (opt-in): only wire the pane-died hook when watchdog=true, so the
# default UX is untouched. window_id/pane_dead_status have no spaces -> no inner
# quoting needed. claude-watchdog re-checks the flag at runtime too.
if [ "$(cs_config_get watchdog false)" = true ]; then
  printf "\n# watchdog: restart crashed instances (opt-in)\nset-hook -g pane-died 'run-shell -b \"%s/claude-watchdog #{window_id} #{pane_dead_status}\"'\n" "$BIN" >> "$CSCONF/bindings.conf"
  echo "wrote    watchdog pane-died hook (watchdog=true)"
fi
case "$(tmux -V)" in *" 3."[2-9]*|*" "[4-9].*) : ;; *)
  echo "warning: tmux >= 3.2 recommended for popups (you have $(tmux -V))" ;;
esac
# Optional deps for the directory picker's typeahead (degrades to Tab completion).
command -v fzf >/dev/null 2>&1 || echo "tip      install 'fzf' for directory typeahead (sudo apt install fzf)"
command -v fd  >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 \
  || echo "tip      install 'fd-find' to speed up the directory search (sudo apt install fd-find)"

# 3. systemd user service (boot autostart of the persistent session) ----------
if command -v systemctl >/dev/null 2>&1; then
  sed -e "s#@REPO@#$REPO#g" \
      -e "s#@TMUX@#$TMUX_BIN#g" \
      -e "s#@TMUX_CONF@#$REPO/tmux.conf#g" \
      -e "s#@SESSION@#$SESSION#g" \
      -e "s#@BIN@#$BIN#g" \
      "$REPO/systemd/claude-tmux.service.in" > "$UNITDIR/claude-tmux.service"
  echo "wrote    $UNITDIR/claude-tmux.service"
  systemctl --user daemon-reload
  if [ "$ENABLE_BOOT" -eq 1 ]; then
    # Best-effort: keep the user manager alive across logout (may need polkit).
    loginctl enable-linger "$USER" 2>/dev/null \
      && echo "linger   enabled for $USER" \
      || echo "linger   NOT enabled (run: sudo loginctl enable-linger $USER)"
    systemctl --user enable --now claude-tmux.service
    echo "enabled  claude-tmux.service"
  else
    echo "skipped  enabling service (--no-boot)"
  fi
else
  echo "skipped  systemd unit (systemctl not found) — start manually with: cj"
fi

# 4. desktop shortcut (only if a terminal emulator + GUI tooling exists) -------
detect_terminal() {
  if [ -n "${TERMINAL:-}" ] && command -v "${TERMINAL%% *}" >/dev/null 2>&1; then
    echo "$TERMINAL"; return
  fi
  for t in x-terminal-emulator konsole gnome-terminal xfce4-terminal \
           kitty alacritty foot wezterm xterm; do
    command -v "$t" >/dev/null 2>&1 && { echo "$t"; return; }
  done
  echo ""
}
term="$(detect_terminal)"
if [ -n "$term" ]; then
  case "${term%% *}" in
    gnome-terminal) exec_line="$term -- $BIN/cj"; tflag=false ;;
    *)              exec_line="$term -e $BIN/cj"; tflag=false ;;
  esac
else
  # No GUI terminal found: let the desktop launch one for us.
  exec_line="$BIN/cj"; tflag=true
fi
sed -e "s#@EXEC@#$exec_line#g" \
    -e "s#@TERMINAL_FLAG@#$tflag#g" \
    "$REPO/applications/claude-join.desktop.in" > "$APPS/claude-join.desktop"
update-desktop-database "$APPS" 2>/dev/null || true
echo "wrote    $APPS/claude-join.desktop (terminal: ${term:-<none, uses default>})"

echo
echo "Done. Join the session with:  cj"
