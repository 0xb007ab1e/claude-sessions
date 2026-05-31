#!/usr/bin/env bash
# install.sh — wire this repo into the current user's environment.
#
# Idempotent: safe to re-run. Regenerates the systemd unit and desktop entry to
# point at wherever this repo is checked out, so it works regardless of clone
# location (not just ~/src/dev/tmux-session).
#
#   ./install.sh            # install + enable boot autostart
#   ./install.sh --no-boot  # install shortcuts/config but don't enable the service
#
# Uninstall: see `uninstall` notes in README.md.

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
UNITDIR="$HOME/.config/systemd/user"
ENABLE_BOOT=1
[ "${1:-}" = "--no-boot" ] && ENABLE_BOOT=0

mkdir -p "$BIN" "$APPS" "$UNITDIR"

# 1. CLI shortcuts on PATH ----------------------------------------------------
for f in claude-session cj restore-claude; do
  ln -sf "$REPO/$f" "$BIN/$f"
  echo "linked  $BIN/$f"
done

# 2. phone-friendly tmux config (source from ~/.tmux.conf, idempotent) --------
line="source-file $REPO/tmux.conf"
touch "$HOME/.tmux.conf"
grep -qxF "$line" "$HOME/.tmux.conf" || echo "$line" >> "$HOME/.tmux.conf"
echo "sourced  $REPO/tmux.conf from ~/.tmux.conf"

# 3. systemd user service (boot autostart of the statically-named session) ----
cat > "$UNITDIR/claude-tmux.service" <<EOF
[Unit]
Description=Persistent tmux session for managing Claude instances
Documentation=file://$REPO/README.md
After=default.target

[Service]
Type=forking
ExecStart=/usr/bin/tmux -f $REPO/tmux.conf new-session -d -s claude
ExecStop=/usr/bin/tmux kill-session -t claude
RemainAfterExit=yes
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
echo "wrote    $UNITDIR/claude-tmux.service"
systemctl --user daemon-reload
if [ "$ENABLE_BOOT" -eq 1 ]; then
  systemctl --user enable --now claude-tmux.service
  echo "enabled  claude-tmux.service (boot autostart; ensure: loginctl enable-linger $USER)"
else
  echo "skipped  enabling service (--no-boot)"
fi

# 4. desktop shortcut ---------------------------------------------------------
cat > "$APPS/claude-join.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude (join tmux)
GenericName=Claude session manager
Comment=Attach to the persistent Claude tmux session and start/reuse an instance
Exec=konsole -e $BIN/cj
Icon=utilities-terminal
Terminal=false
Categories=Development;Utility;
Keywords=claude;tmux;ai;
EOF
update-desktop-database "$APPS" 2>/dev/null || true
echo "wrote    $APPS/claude-join.desktop"

echo
echo "Done. Join the session with:  cj"
