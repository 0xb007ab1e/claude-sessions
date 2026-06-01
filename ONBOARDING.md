# Onboarding — managing Claude Code instances with `claude-sessions`

This workflow keeps multiple **Claude Code** instances in one persistent **tmux**
session you can drive from your laptop or your **phone** (over Tailscale + Termux).
Each instance is a named, colored window; you can list/switch/stop/reopen them,
drop to a shell, and get a phone notification when one needs you.

Repo: **https://github.com/0xb007ab1e/claude-sessions** (checkout on this machine:
`~/src/dev/tmux-session`).

## Get set up (one time)

```bash
git clone https://github.com/0xb007ab1e/claude-sessions.git
cd claude-sessions
./install.sh                 # symlinks tools, tmux config, systemd unit, desktop entry
sudo apt install -y fzf fd-find   # optional: directory typeahead (recommended)
```

`install.sh` is portable + idempotent (no hardcoded user/path/host). A systemd
**user service** starts the session at boot and it survives logout (linger).

## Daily workflow

```bash
cj            # join the persistent session (reuses an idle window or opens one)
```
Inside the session, everything is one keypress away. Prefix is **`Ctrl-b`**.

| Action | Key | Menu |
|---|---|---|
| **Open the menu** | `prefix C` (or **`F9`**, or **tap the session name** in the status bar) | — |
| List instances (active + closed) | `prefix L` | List |
| New instance (current dir) | `prefix N` | New |
| New instance in a chosen dir (fzf typeahead) | `prefix D` | New in dir… |
| Rename instance | `prefix E` | Rename |
| Resume a past conversation | `prefix R` | Resume |
| Reopen a closed instance (exact convo, in its dir) | `prefix O` | Reopen closed |
| Stop current instance | `prefix X` | Stop |
| Interactive shell (sudo, logins, etc.) | `prefix B` | Shell here |
| Cheat sheet | `prefix ?` | Cheat sheet |

No function keys on your phone? **Tap the session name** (far left of the status
bar) to open the menu, or use `prefix` + the letter. Switch instances with
`F7`/`F8`, `Alt+←/→`, the menu's *Switch instance*, or tap a window name.

CLI equivalents: `claude-ls`, `claude-new [-m resume|continue] [-D]`,
`claude-restore`, `claude-restore-all`, `claude-rename`, `claude-shell`,
`claude-session` (multi-window layouts).

## From your phone (Tailscale + Termux)

```bash
ssh <your-host> -t 'bash -lc cj'          # join (login shell so PATH is set)
ssh <your-host> -t 'tmux attach -t claude'
```
The session is reachable over your tailnet; instances keep running when you detach.

## Configure it

`~/.config/claude-sessions/config` (`key = value`):

| Key | What |
|---|---|
| `name_scheme` | `nato` / `project` / `random` — how instances are auto-named |
| `auto_name` | `true` to auto-name every `cj` (or use `cj -a`) |
| `notify` | `desktop` / `ntfy` / `pushover` / `none` — alert when an instance rings the bell (enable the bell in Claude); `ntfy`/`pushover` push to your phone |
| `restore_on_boot` | `true` to reopen the previous session's instances at boot |
| `search_dir` | root the directory picker searches (e.g. `~/src`) |

## Good to know

- **One session, many windows** — each window is a Claude instance with a stable
  name + color in the status bar and in `claude-ls`.
- **Closed instances** are remembered (with their directory + exact conversation
  id) so **Reopen closed** brings them right back.
- **`claude` is not shadowed** — `cj` joins the session; plain `claude` still runs
  a normal, non-tmux instance.
- Manage the boot service: `systemctl --user {status,restart} claude-tmux.service`.

## Develop / verify

```bash
bats tests/                  # unit tests for lib.sh
bash tests/integration.sh    # end-to-end picker + popup test (private tmux socket)
```
Full reference (every script + function): open `docs/index.html`.
