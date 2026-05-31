# claude-sessions

Manage and stream multiple **Claude Code** instances inside a single, persistent
tmux session — built to be reached from a phone over Tailscale + Termux, and
tuned for a small touchscreen. One tmux session, one Claude per window.

Portable by design: no hardcoded users, paths, hosts, or terminals. Everything
is resolved at install time from your checkout location and environment.

Full docs: [`docs/index.html`](docs/index.html).

## Quick start

```bash
git clone https://github.com/0xb007ab1e/claude-sessions.git
cd claude-sessions
./install.sh          # symlinks + tmux config + systemd unit + desktop entry
cj                    # join the session
```

## Persistent session + `cj` (primary workflow)

A tmux session (named `claude` by default) is started **at boot** by a systemd
*user* service, so it's always there to attach to and survives logout (linger
enabled by the installer). Join it with **`cj`** ("claude-join"):

```bash
cj          # attach; reuse an idle window for a fresh Claude, else open a new one
```

- Inside tmux already, `cj` just runs the real `claude` in the current pane.
- `cj` does **not** shadow `claude` — `claude` still starts a plain, non-tmux instance.
- A desktop entry ("Claude (join tmux)") runs `cj` in your terminal — a clickable shortcut.

Manage the service:

```bash
systemctl --user status  claude-tmux.service
systemctl --user restart claude-tmux.service     # reset to a clean single window
systemctl --user disable --now claude-tmux.service
```

## Install

```bash
./install.sh             # install + enable boot autostart
./install.sh --no-boot   # install shortcuts/config, skip enabling the service
```

The installer resolves its own checkout path, finds `tmux` and a terminal
emulator, and fills the unit/desktop **templates** (`*.in`) accordingly — so it
works from any clone location, user, or machine. It's idempotent; re-run it any
time. Environment overrides:

| Variable | Effect |
|---|---|
| `CLAUDE_TMUX_SESSION` | Session name (default `claude`) — honored by `cj`, `claude-session`, and the unit |
| `TERMINAL` | Preferred terminal emulator for the desktop shortcut |
| `CJ_CLAUDE` | Path to the Claude binary if not on `PATH` |

If `loginctl enable-linger` needs privileges on your system, run it once:
`sudo loginctl enable-linger "$USER"`.

**Uninstall:**

```bash
systemctl --user disable --now claude-tmux.service
rm -f ~/.config/systemd/user/claude-tmux.service
rm -f ~/.local/share/applications/claude-join.desktop
rm -f ~/.local/bin/cj ~/.local/bin/claude-session
# then remove the `source-file …/tmux.conf` line from ~/.tmux.conf
```

## Repo layout

| Path | What |
|---|---|
| `cj` | Primary join command (claude-join) |
| `claude-session` | General launcher — one Claude per window in a named session |
| `tmux.conf` | Phone-friendly tmux settings |
| `install.sh` | Portable, idempotent installer |
| `systemd/claude-tmux.service.in` | Template for the boot-autostart user service |
| `applications/claude-join.desktop.in` | Template for the desktop shortcut |
| `docs/index.html` | Full documentation (every script/function) |

## `claude-session` — build a custom layout

Each argument is a window, `name[:dir[:mode]]`:

```bash
claude-session frontend backend docs
claude-session api:~/src/api web:~/src/web        # name:dir sets the start dir
claude-session app:~/src/app:continue notes::resume   # per-window resume mode
```

- `mode` is `continue` (`claude --continue`), `resume` (`claude --resume`), or
  omitted/`new` for a fresh instance. Use `name::resume` to set only the mode.
- This replaces the old single-purpose recovery script: rebuild any resume
  layout with explicit `…:dir:continue` / `…:dir:resume` windows.

## Reaching it from a phone (Tailscale + Termux)

Replace `<host>` with your machine's MagicDNS name or Tailscale IP:

```bash
ssh <host> -t 'bash -lc cj'             # login shell so ~/.local/bin is on PATH
ssh <host> -t 'tmux attach -t claude'   # plain attach (tmux is on the default PATH)
ssh <host> -t 'claude-session -g'       # grouped view: own size, won't resize the other client
```

### Why `-g` from a second client

tmux resizes a shared session to the **smallest** attached client. If a desktop
is also attached, the phone's narrow width squeezes Claude's TUI everywhere.
`-g` creates a *grouped* view that shares the same windows but sizes
independently (and self-destroys when that client disconnects).

## Navigation (phone)

| Action | Keys |
|---|---|
| Window menu (best on mobile) | `Ctrl-b w` |
| Next / previous window | `Ctrl-b n` / `Ctrl-b p` |
| Jump to window N | `Ctrl-b 1` … `Ctrl-b 9` |
| Detach (leave running) | `Ctrl-b d` |

Mouse mode is on, so you can also **tap the status bar** to switch windows.

## `claude-session` options

| Flag | Effect |
|---|---|
| `-s NAME` | Session name (default `$CLAUDE_TMUX_SESSION` or `claude`) |
| `-g` | Grouped attach view, independent size |
| `-n` | Create the session but stay detached |
| `-h` | Help |
