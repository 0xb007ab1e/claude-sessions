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

The menu (`prefix C` / `F9` / tap the status bar):

![claude-sessions instance menu](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-menu.png)

| Action | Key | Menu |
|---|---|---|
| **Open the menu** | `prefix C` (or **`F9`**, or **tap the session name** in the status bar) | — |
| List instances (active + closed) | `prefix L` | List |
| New instance (current dir) | `prefix N` | New |
| New instance in a chosen dir (fzf typeahead) | `prefix D` | New in dir… |
| Rename instance | `prefix E` | Rename |
| Change the current instance's directory (relaunch + resume) | `prefix G` | Change dir |
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

## Screenshots — menu actions & status bar

What every menu action looks like (rendered mockups), in menu order. Base:
`…/main/docs/screenshots/`.

**Switch instance** (menu `s`) — tmux choose-tree, works in any terminal
![Switch instance](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-switch.png)

**List instances** (`prefix L` / menu `l`)
![List instances](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-list.png)

**New instance** (`prefix N` / menu `n`)
![New instance](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-new.png)

**New in dir…** (`prefix D` / menu `d`) — fzf typeahead over `search_dir`
![New in dir](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-new-in-dir.png)

**Rename instance** (`prefix E` / menu `e`)
![Rename instance](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-rename.png)

**Shell here** (`prefix B` / menu `b`)
![Shell here](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-shell.png)

**Resume conversation** (`prefix R` / menu `r`)
![Resume conversation](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-resume.png)

**Reopen closed** (`prefix O` / menu `o`)
![Reopen closed](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-reopen-closed.png)

**Restore last session** (menu `a`)
![Restore last session](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-restore-all.png)

**Stop current** (`prefix X` / menu `x`)
![Stop current](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-stop.png)

**Cheat sheet** (`prefix ?` / menu `?`)
![Cheat sheet](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/instances-cheat-sheet.png)

**Status bar** (the session list at the bottom of the screen)
![Status bar](https://raw.githubusercontent.com/0xb007ab1e/claude-sessions/main/docs/screenshots/status-bar.png)

## Phone setup (Tailscale + Termux)

Reach the session from your phone over your private tailnet — no port-forwarding,
no public exposure.

### 1. Tailscale (one-time)

**On the machine** running the session:
```bash
# Debian/Ubuntu/Parrot:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up                 # sign in (opens a browser/URL)
sudo systemctl enable --now ssh   # make sure sshd is running
tailscale status                  # note the machine's MagicDNS name (e.g. host.tailnet.ts.net)
tailscale ip -4                   # …or its 100.x.y.z address
```

**On the phone:** install the **Tailscale** app (Play Store / App Store), sign in
to the **same** account/tailnet, and toggle it on. The phone can now reach the
machine by its MagicDNS name or `100.x` IP.

### 2. Termux (one-time)

1. Install **Termux** (F-Droid is recommended over the Play Store build).
2. Install an SSH client and set up a key:
   ```bash
   pkg update && pkg install openssh
   ssh-keygen -t ed25519           # press Enter through the prompts
   # then authorize it on the machine (run once):
   ssh-copy-id <user>@<host>       # <host> = MagicDNS name or 100.x IP
   ```
3. *(Optional, recommended)* add keys Termux's touch keyboard lacks — so the tmux
   prefix (`Ctrl-b`), completion (`Tab`) and `F7/F8/F9` work. Edit
   `~/.termux/termux.properties`:
   ```
   extra-keys = [['ESC','CTRL','ALT','TAB','-','F7','F8','F9','?']]
   ```
   then long-press Termux → **Reload settings**.
4. *(Optional)* a one-tap alias — add to Termux `~/.bashrc`:
   ```bash
   alias cj='ssh <user>@<host> -t "bash -lc cj"'
   ```

### 3. Connect

```bash
ssh <user>@<host> -t 'bash -lc cj'        # join the session (login shell so PATH has ~/.local/bin)
ssh <user>@<host> -t 'tmux attach -t claude'   # or just attach
```
Instances keep running when you disconnect. On the phone you don't need function
keys: **tap the session name** (far left of the status bar) to open the menu, or
press `Ctrl-b` (from the extra-keys row) then a letter. Switch instances by
tapping a window name in the status bar.

> Tip: replace `<host>` with the MagicDNS name from `tailscale status`. For a
> nicer name/HTTPS you can also use `tailscale serve` from the [README](README.md).

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
