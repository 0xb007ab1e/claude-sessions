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

## Naming, listing & hotkeys

**Auto-name instances** (optional) so the list and status bar are readable:

```bash
cj -a                 # auto-name using your configured scheme
cj -a project         # override the scheme for this call (nato|project|random)
cj -n api             # explicit name
```

Pick your **naming convention** in `~/.config/claude-sessions/config`
(`name_scheme = nato | project | random`), override per-shell with
`$CLAUDE_NAME_SCHEME`, or per-call with `-a SCHEME`. Set `auto_name = true` to
auto-name every `cj` without the flag. Each instance gets a stable **color**.

**List** active + closed instances anytime:

```bash
claude-ls             # colored: ● active   ○ closed (with dir + uptime/closed-ago)
```

The list is backed by a registry at `~/.local/state/claude-sessions/registry.tsv`;
instances flip to *closed* automatically when their window goes away.

**Hotkeys** (prefix is `Ctrl-b`) — discover them all via the menu or cheat sheet:

| Key | Action |
|---|---|
| `prefix + C` | **menu** of all actions below |
| `prefix + L` | list instances — selectable picker (Enter: switch active / reopen closed) |
| `prefix + N` | new instance (in the current window's directory) |
| `prefix + D` | new instance in a directory you type ("New in dir…") |
| `prefix + E` | rename the current instance |
| `prefix + G` | change the current instance's directory (relaunch + resume) |
| `prefix + B` | open an interactive shell in the current dir ("Shell here") |
| `prefix + R` | resume a past conversation |
| `prefix + O` | reopen a closed instance |
| `prefix + X` | stop the current instance (confirm) |
| `prefix + ?` | cheat sheet |

**No prefix needed** (works inside a running Claude, which otherwise captures every
key — a bare key or `Ctrl-C` goes to Claude, not tmux):

| Key | Action |
|---|---|
| `F9` | open the instance menu (one key) |
| `F9` then `s` | switch instance (built-in chooser — works in any terminal) |
| `F7` / `F8` | previous / next instance (portable everywhere) |
| `Alt + ←/→` | previous / next (if your terminal sends these) |
| **tap the session name** (far left of the status bar) | **open the menu** — best on phones/Termux (no function keys) |
| mouse | tap a window name in the status bar to switch |

CLI equivalents: `claude-pick` (selectable list), `claude-new [-m resume|continue]`,
`claude-restore`, `claude-ls`, `claude-rename [name]`, `claude-cd` (move the
current instance to another directory, resuming), `claude-shell` (an interactive
shell for commands Claude can't run — `sudo`, logins, etc.). Trim closed history
with `claude-ls --prune [N]`.

**Choosing the directory:** a new instance opens in the current window's
directory by default. To pick one, use **New in dir…** (`prefix + D`) or
`claude-new -c <dir>` / `claude-new -D` (prompts). **Reopen closed** also prompts
for the directory (prefilled with the saved one) so you can override it.

The directory prompt has **Tab path-completion**, and upgrades to a live **fzf
typeahead picker** if `fzf` is installed (`sudo apt install fzf fd-find`) — handy
on a phone. The picker searches recently-used dirs plus the tree under
**`search_dir`** in config (default `$HOME`; set it to e.g. `~/src` to scope the
list to your projects).

### Tab-completion & tests

The installer sources `completions/claude-sessions.bash` from `~/.bashrc`
(flags + scheme values for `cj`/`claude-new`/`claude-ls`/`claude-session`).
Unit tests for `lib.sh` are in `tests/lib.bats` — run `bats tests/`. An
end-to-end test is in `tests/integration.sh` (`bash tests/integration.sh`) — it
drives the fzf picker via `tmux send-keys` in a pane **and** runs `claude-new`
through a real `display-popup`, on a private socket; it skips cleanly without
`tmux`/`fzf`.

### Attention notifications

`install.sh` registers **Claude Code hooks** (`claude-hook`) that track each
instance's status (working / idle / needs-approval) and fire `claude-notify`
**precisely when an instance needs your approval** — no reliance on the terminal
bell. Set `notify_on_finish = true` to also ping when an instance finishes a turn.
Choose the backend in config (`notify = desktop | ntfy | pushover | none`);
`ntfy`/`pushover` push to your **phone** (over Tailscale for self-hosted ntfy) at
**high priority** with a 🔔 tag. The window is also flagged **yellow** in the
status bar on a terminal bell. See `config.example`.

> Hooks are merged into `~/.claude/settings.json` (idempotent, backup kept) and
> apply to instances started after install.

### Restore the whole session after a reboot

The service snapshots active instances on stop (`claude-snapshot`) and, with
`restore_on_boot = true` in config, reopens them at boot (`claude-restore-all`).
Run it manually anytime (`claude-restore-all`) or from the menu ("Restore last
session"). Snapshots are taken on graceful stop; a hard power-loss reboot reuses
the previous snapshot.

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
| `CLAUDE_TMUX_SESSION` | Session name (default `claude`) — honored by every tool and the unit |
| `CLAUDE_NAME_SCHEME` | Naming scheme (`nato`/`project`/`random`) — overrides config |
| `TERMINAL` | Preferred terminal emulator for the desktop shortcut |
| `CJ_CLAUDE` | Path to the Claude binary if not on `PATH` |

Config lives at `~/.config/claude-sessions/config` (created from `config.example`
if absent). If `loginctl enable-linger` needs privileges, run once:
`sudo loginctl enable-linger "$USER"`.

**Uninstall:**

```bash
systemctl --user disable --now claude-tmux.service
rm -f ~/.config/systemd/user/claude-tmux.service ~/.config/claude-sessions/bindings.conf
rm -f ~/.local/share/applications/claude-join.desktop
rm -f ~/.local/bin/cj ~/.local/bin/claude-*   # cj + all claude-* tools (not the real `claude`)
# then remove the `source-file …/tmux.conf` line from ~/.tmux.conf
# and the claude-hook entries from ~/.claude/settings.json (restore settings.json.cs-bak)
```

## Repo layout

| Path | What |
|---|---|
| `cj` | Primary join command (claude-join); `-a` auto-names |
| `claude-ls` / `claude-pick` / `claude-new` / `claude-restore` | List / pick (switch·reopen) / open / reopen instances |
| `claude-cd` / `claude-rename` / `claude-shell` | Move dir (resume) / rename / shell |
| `claude-popup` | Run a view inside a tmux popup |
| `claude-session` | General launcher — one Claude per window in a named session |
| `lib.sh` | Shared helpers: config, naming, colors, registry |
| `config.example` | Default config (`name_scheme`, `auto_name`) |
| `tmux.conf` | Phone-friendly tmux settings (sources the key bindings) |
| `tmux/bindings.conf.in` / `tmux/cheatsheet.txt` | Menu + key bindings template; cheat sheet |
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
