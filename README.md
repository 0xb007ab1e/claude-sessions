# tmux-session

Stream multiple **Claude Code** instances from this laptop (`parrot`) to a phone
(`johns-note20`) over Tailscale + Termux. One tmux session, one Claude per window,
tuned for a small touchscreen.

Full docs: [`docs/index.html`](docs/index.html).

## Persistent session + `cj` (primary workflow)

A statically-named `claude` tmux session is started **at boot** by a systemd
user service (`~/.config/systemd/user/claude-tmux.service`), so it's always
there to attach to and survives logout (linger enabled).

Join it with **`cj`** ("claude-join"):

```bash
cj                 # attach; reuse an idle window for a fresh Claude, else new window
```

- Inside tmux already, `cj` just runs the real `claude` in the current pane.
- `cj` does **not** shadow `claude` — `claude` still starts a plain, non-tmux instance.
- A desktop shortcut (`~/.local/share/applications/claude-join.desktop`,
  "Claude (join tmux)") runs `cj` in a Konsole window — the static clickable.

Manage the service:

```bash
systemctl --user status claude-tmux.service
systemctl --user restart claude-tmux.service     # reset to a clean single window
systemctl --user disable --now claude-tmux.service
```

From the phone, join the same session over SSH:

```bash
ssh parrot -t 'bash -lc cj'            # login shell so ~/.local/bin is on PATH
ssh parrot -t 'tmux attach -t claude'  # plain attach (tmux is on the default PATH)
```

---


## Repo layout

| Path | What |
|---|---|
| `cj` | Primary join command (claude-join) |
| `claude-session` | General launcher — one Claude per window in a named session |
| `restore-claude` | Rebuild the 6-window resume layout (recovery helper) |
| `tmux.conf` | Phone-friendly tmux settings |
| `install.sh` | Idempotent installer (symlinks, config, service, desktop entry) |
| `systemd/claude-tmux.service` | Boot autostart of the persistent session |
| `applications/claude-join.desktop` | Desktop shortcut that runs `cj` |
| `docs/index.html` | Full documentation (every script/function) |

## Install

```bash
git clone https://github.com/0xb007ab1e/claude-sessions.git
cd claude-sessions
./install.sh                 # symlinks + tmux config + systemd unit + desktop entry
# (one-time, survives logout)   loginctl enable-linger "$USER"
```

`install.sh` regenerates the systemd unit and desktop entry to point at wherever
you cloned the repo, so it isn't tied to `~/src/dev/tmux-session`. Use
`./install.sh --no-boot` to skip enabling the boot service.

**Uninstall:**

```bash
systemctl --user disable --now claude-tmux.service
rm -f ~/.config/systemd/user/claude-tmux.service ~/.local/share/applications/claude-join.desktop
rm -f ~/.local/bin/{cj,claude-session,restore-claude}
# then remove the `source-file …/tmux.conf` line from ~/.tmux.conf
```

## Use it

On the laptop — start one Claude per window:

```bash
claude-session frontend backend docs
claude-session api:~/src/api web:~/src/web   # name:dir sets the start dir
```

Detach with `Ctrl-b d`. The session keeps running.

From the phone (Termux):

```bash
ssh parrot -t 'tmux attach -t claude'        # share the laptop's view
ssh parrot -t 'claude-session -g'            # OR: own size, won't shrink laptop
```

### Why `-g` from the phone

tmux resizes a shared session to the **smallest** attached client. If the laptop
is also attached, the phone's narrow width squeezes Claude's TUI everywhere.
`-g` creates a *grouped* view that shares the same windows but sizes
independently (and self-destroys when the phone disconnects).

## Navigation (phone)

| Action | Keys |
|---|---|
| Window menu (best on mobile) | `Ctrl-b w` |
| Next / previous window | `Ctrl-b n` / `Ctrl-b p` |
| Jump to window N | `Ctrl-b 1` … `Ctrl-b 9` |
| Detach (leave running) | `Ctrl-b d` |

Mouse mode is on, so you can also **tap the status bar** to switch windows.

## Options

| Flag | Effect |
|---|---|
| `-s NAME` | Session name (default `claude`) |
| `-g` | Grouped attach view, independent size — use from the phone |
| `-n` | Create the session but stay detached |
| `-h` | Help |
