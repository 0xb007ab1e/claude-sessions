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

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SESSION="${CLAUDE_TMUX_SESSION:-claude}"
ENABLE_BOOT=1
[ "${1:-}" = "--no-boot" ] && ENABLE_BOOT=0

TMUX_BIN="$(command -v tmux || true)"
[ -n "$TMUX_BIN" ] || { echo "error: tmux not found on PATH" >&2; exit 1; }

mkdir -p "$BIN" "$APPS" "$UNITDIR"

# 1. CLI shortcuts on PATH ----------------------------------------------------
for f in cj claude-session; do
  ln -sf "$REPO/$f" "$BIN/$f"
  echo "linked   $BIN/$f"
done

# 2. phone-friendly tmux config (sourced from ~/.tmux.conf, idempotent) -------
line="source-file $REPO/tmux.conf"
touch "$HOME/.tmux.conf"
grep -qxF "$line" "$HOME/.tmux.conf" || echo "$line" >> "$HOME/.tmux.conf"
echo "sourced  $REPO/tmux.conf from ~/.tmux.conf"

# 3. systemd user service (boot autostart of the persistent session) ----------
if command -v systemctl >/dev/null 2>&1; then
  sed -e "s#@REPO@#$REPO#g" \
      -e "s#@TMUX@#$TMUX_BIN#g" \
      -e "s#@TMUX_CONF@#$REPO/tmux.conf#g" \
      -e "s#@SESSION@#$SESSION#g" \
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
