# Plan: instance watchdog / reconnectivity (auto-restart crashed instances)

Status: **PROPOSAL — not implemented.** Opt-in via a `watchdog` flag (default off).

## Goal
When a managed Claude instance dies unexpectedly (the `claude` process crashes
or the pane's command exits abnormally), detect it and **automatically relaunch
it, resuming the same conversation** — without restarting cleanly-exited or
user-stopped instances, and without thrashing on a perma-crashing instance.

We already have everything needed to restart precisely: the JSONL registry holds
each instance's `window_id`, `cwd`, `transcript` (exact conversation), `model`,
and `effort`. A restart is therefore: relaunch `claude --resume <transcript>`
(else `--continue`) in `cwd`, re-applying `model`/`effort` — exactly what
`claude-new -i` / `claude-restore` already do.

Scope note: "reconnectivity" here = restarting crashed **instances**. Session-level
reconnect is already handled — the systemd `claude-tmux.service` keeps the tmux
session alive across logout, and `cj` / `tmux attach` reconnect a client.

## The hard part: crash vs. intentional exit
A restart loop must only fire on **unexpected** death:

| Event | Should restart? | Signal |
|---|---|---|
| `prefix X` / `claude-stop` (kill-window) | No | tooling marks the registry row `closed` first |
| `claude-cd` (move dir) | No | it kills the old window deliberately, marks closed |
| `/exit` in Claude (clean, exit 0) | No | pane dies with exit status 0 |
| Claude crash / OOM / killed (exit ≠ 0) | **Yes** | pane dies with nonzero exit status |
| Machine reboot | (separate) | handled by `restore_on_boot`, not the watchdog |

Today the `window-unlinked` hook runs `cs_reconcile`, which flips any vanished
`active` row to `closed` — so by the time we'd inspect it, a crash looks the same
as a clean stop. **The watchdog must observe the death with its exit status
before the row is closed.** That constraint drives the approach choice below.

## Approaches considered

### A. tmux `remain-on-exit` + `pane-died` hook  (event-driven) — RECOMMENDED
Set `remain-on-exit on` for managed windows so a finished pane stays in a **dead**
state (window not unlinked) instead of closing. Bind `set-hook -g pane-died` to a
`claude-watchdog` handler that reads `#{pane_dead_status}` (the exit code):
- exit `0` → clean stop → leave dead / let reconcile close it.
- exit `≠ 0` and `watchdog` on and retry budget left → `respawn-pane` running
  `claude --resume <transcript>` (from the registry) → instance is back in the
  same window, same conversation.

**Pros**
- Instant, event-driven; no daemon or polling latency.
- Native tmux; the dead-pane state keeps the window (and its registry row)
  intact, so we can read the exit status and the transcript before anything
  closes it — cleanly separating crash from clean exit.
- Restart reuses the exact window id, dir, and transcript.

**Cons**
- `remain-on-exit on` changes UX (a crashed/clean pane lingers as "dead [exited]"
  until respawned/closed) — must scope it to managed windows, not globally.
- `pane-died` handler runs in tmux's run-shell context (no pane stdin); must be
  careful and fast.
- Needs crash-loop protection (see below) or a fast-crashing instance respawns
  forever.

### B. Polling watchdog (systemd user timer, or a loop)
A `claude-watchdog` oneshot runs every N seconds (via `claude-watchdog.timer`):
for each `active` registry row, if its window is gone **or** its pane is no
longer running `claude`, restart it.

**Pros**
- Simple mental model; centralized; trivially supports backoff/retry counters.
- Also catches "window still open but Claude died back to a shell" — which the
  pane-died hook may miss if the shell (not claude) is the pane command.
- Independent of tmux hook quirks.

**Cons**
- Up to N seconds of latency.
- A timer/daemon to install and manage.
- Crash vs. intentional is murkier: relies entirely on the registry being marked
  `closed` for every intentional stop (any missed instrumentation → it "restarts"
  something the user deliberately closed). The `window-unlinked → reconcile`
  behavior would also need to be suppressed (or it closes crashed rows, hiding
  them from the watchdog).

### C. systemd service per instance (`Restart=on-failure`)  — REJECTED
Run each instance as its own user service so systemd restarts it.
**Pros:** native restart/backoff (`Restart`, `RestartSec`, `StartLimitBurst`).
**Cons:** instances stop being tmux windows — guts the entire tmux-window model,
the registry, the picker, navigation, the menu. Not worth it.

### D. Hybrid (A primary + B as a low-frequency backstop)
`pane-died` for instant restarts; a slow (e.g. 2-min) poll to catch edge cases A
misses (pane fell back to a shell, hook lost). Best coverage, most moving parts.

## Recommendation
**Approach A**, gated by the `watchdog` flag, with crash-loop protection and a
give-up notification. Add **D**'s slow poll only if real-world gaps appear.

## Crash-loop protection
Track per-window restart attempts (a sidecar `state/watchdog/<window_id>` or new
registry fields `restarts`/`last_restart`):
- `watchdog_max_retries` (default 3) within `watchdog_window` seconds (default 60).
- Exponential `watchdog_backoff` (default 5s, ×2 each retry).
- If an instance lives longer than `watchdog_window`, reset its retry count.
- On exhausting retries: **stop restarting**, leave the pane dead, and fire
  `claude-notify` ("instance `<name>` keeps crashing — gave up after N tries").

## Flag / config design
All in `~/.config/claude-sessions/config` (read via `cs_config_get`):

```
watchdog              = false   # master switch (opt-in)
watchdog_max_retries  = 3       # max restarts within the window
watchdog_window       = 60      # seconds; living longer resets the retry count
watchdog_backoff      = 5       # seconds, doubled each retry
watchdog_restart_on   = crash   # crash (exit≠0) | always | never
```

Per-instance override (future): a `cj --no-watchdog` / a registry `watchdog`
column so one instance can opt out. v1 keeps it config-global.

The `pane-died` hook and `remain-on-exit` are emitted into the generated
`bindings.conf` **only when `watchdog = true`** (install.sh already templates
that file), so the behavior change is fully opt-in and leaves the default UX
untouched.

## New pieces (if approved)
- `claude-watchdog <window_id> <dead_status>` — decides + performs the restart
  (reads registry, checks retry budget/backoff, `respawn-pane` with the resume
  command, or gives up + notifies). Used by the `pane-died` hook.
- lib helpers: `cs_watchdog_enabled`, retry-counter get/set/reset.
- install.sh: conditionally add `setw remain-on-exit on` (managed windows) +
  `set-hook pane-died` to `bindings.conf` when `watchdog = true`.
- config.example + docs; bats for the decision logic (crash vs clean, retry/backoff,
  give-up) using a stubbed tmux; an integration test that kills a stub instance
  and asserts it respawns.

## Open questions
1. Restart **in place** (`respawn-pane`, same window id) vs. a **new window**
   (`claude-new`, new id, old row closed)? In-place keeps ids/layout stable and
   is the natural fit for `remain-on-exit`; new-window reuses existing code.
2. Should a clean `/exit` (status 0) ever auto-restart? Default **no**
   (`watchdog_restart_on = crash`); `always` available for "keep it running."
3. Notify on **every** restart, only on **give-up**, or configurable? Proposed:
   give-up always; per-restart behind `notify_on_finish`-style toggle.
4. Interaction with `restore_on_boot`: watchdog handles in-session crashes; boot
   restore handles reboots. Keep them separate (no overlap).
