# Mobile — one-tap join from your phone

Turn the SSH-attach command into a home-screen shortcut so you land in the
in-progress `claude` fleet with a single tap. The fleet is persistent
(systemd + tmux), so this is purely a *client* convenience — nothing here runs
on the server except the `claude-session` it attaches.

The shortcut runs, in effect:

```bash
ssh -t <host> 'bash -lc "claude-session -g"'
```

`-g` is a **grouped** attach: a throwaway session sharing the base fleet's
windows but sized to *this* client, that self-destructs on disconnect. It lets
the phone attach without resizing a desktop that's also attached (tmux otherwise
shrinks a shared session to the smallest client). `claude-join` falls back to
`cj` if the fleet isn't up yet.

## Android + Termux (recommended)

1. **Install Termux + Termux:Widget** from the **same source** (F-Droid or
   GitHub). Play-Store builds are deprecated and the app + add-on won't work
   together.
2. **Install the shortcut script:**
   ```bash
   mkdir -p ~/.shortcuts
   # copy claude-join.example from this repo onto the phone, e.g.:
   #   scp <host>:_src/_dev/tmux-session/mobile/claude-join.example ~/.shortcuts/claude-join
   $EDITOR ~/.shortcuts/claude-join        # set HOST=<your Tailscale name/IP>
   chmod 700 ~/.shortcuts ~/.shortcuts/claude-join
   ```
3. **Pin the icon:** home screen → long-press → **Widgets** → **Termux:Widget**
   → drop the **1×1 "Termux shortcut"** and choose **`claude-join`**. (The
   resizable list widget shows every script in `~/.shortcuts/` instead.)

> Keep the script directly in `~/.shortcuts/` — scripts in `~/.shortcuts/tasks/`
> run headless, but you want the interactive tmux UI.

## Make it truly one-tap (passwordless)

If the shortcut ever prompts for a password, switch to key auth:

```bash
# in Termux, once:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id <host>      # or: cat ~/.ssh/id_ed25519.pub | ssh <host> 'cat >> ~/.ssh/authorized_keys'
```

A `~/.ssh/config` on the phone keeps it tidy and detects dropped links:

```
Host box
    HostName <tailscale-name-or-ip>
    User <you>
    RequestTTY yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

With `RequestTTY yes` you can drop `-t`; the script body can become
`exec ssh box 'bash -lc "claude-session -g"'`.

## Optional upgrades

- **mosh** — survives network switches, sleep/wake, and IP changes (ideal on a
  phone). `pkg install mosh` in Termux (and `mosh` on the host), then make the
  script `exec mosh <host> -- bash -lc 'claude-session -g'`. The persistent fleet
  means even a hard drop is just a re-tap away.
- **Tailscale SSH** — `tailscale up --ssh` on the host (plus an ACL that allows
  it) authenticates connections via your tailnet identity, so you manage no SSH
  keys at all.

## Without Termux

**JuiceSSH** (or similar): save a connection to `<host>`, set **"run snippet on
connect"** to `claude-session -g`, then create a **home-screen shortcut** to that
connection — same one-tap result, no scripts.

## Navigating the fleet on a phone (no function keys)

- **Tap the session name** (far left of the status bar) → the action menu.
- **Tap a window name** → switch to it.
- **`Alt+←/→`** (Termux extra-keys row) → previous / next instance.
- **`Ctrl-b`** then: `w` window menu · `n`/`p` next/prev · `1`–`9` jump ·
  `d` detach (leaves everything running).

## Notifications → your phone

If `notify = ntfy` in `~/.config/claude-sessions/config`, install the **ntfy**
app and **subscribe to your configured topic** to get a 🔔 push exactly when an
instance needs approval. Set `notify_on_finish = true` to also ping at
end-of-turn. (`ntfy`/`pushover` reach the phone; for self-hosted ntfy, over
Tailscale.)
