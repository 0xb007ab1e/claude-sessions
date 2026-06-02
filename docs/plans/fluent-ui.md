# Plan: Fluent-style UI refactor + grouped ephemeral shells

Status: **PROPOSAL — for review.** Decisions so far: ephemeral shells are spawned
**manually** via `claude-shell`; the **grouping architecture is deferred**
("skip for now" — Part 3); deliver as **separate feature branches**.

## Goals
1. Apply a **fluent design language** to the TUI — favour **grouping + drill-down
   hierarchy** over flat lists, with consistent labels/glyphs and a tidy status
   bar. Concretely: refactor the action menu (`prefix+C` / `F9`) into grouped
   submenus.
2. **Ephemeral session shells** — when Claude suggests an interactive `!`
   command, spawn a shell (the existing `claude-shell`) **labelled by its pwd**
   and **attached to its parent instance's group**, taskbar-style.

Two constraints established up front:
- tmux has **no native intra-session window grouping** (windows are a flat list).
  True "taskbar groups" need either a session-per-instance model or a faked
  grouping (naming/order/colour + custom status bar). → **Part 3, deferred.**
- There is **no Claude Code hook** for "Claude suggested a `!` command", so
  auto-spawning is out of scope here; spawning is **manual** via `claude-shell`.

---

## Part 1 — Fluent grouped, drill-down menus  (branch `feat/fluent-menus`)
Today `prefix+C` / `F9` open one **flat** `display-menu` (~9 items). Refactor to a
top-level menu of **groups**, each opening a submenu (tmux supports this: a menu
item whose command is another `display-menu`):

```
 claude ┐
        ├─ ▸ Instances      New · New in dir… · Rename · Switch · List · Stop
        ├─ ▸ Conversations  Resume · Reopen closed · Restore last session
        ├─ ▸ Shell          New shell here · New shell in dir…        (Part 2)
        ├─ ▸ Model/effort    set per-instance model · effort
        └─ ▸ Help           Cheat sheet · About
```

- Consistent **leading glyphs** (`▸` = drill-down, action icons), aligned labels,
  generous grouping — the "fluent" feel within a TUI menu.
- Submenus = nested `display-menu` invocations generated into `bindings.conf.in`.
- **Keep the flat direct keys** (`prefix+N/R/O/X`, `F7/F8/F9`) for power users —
  the menu becomes the *discoverable, grouped* surface; nothing gets slower for
  people who know the keys.
- Optional status-bar polish: a fluent accent colour + clearer segment grouping
  (instances vs shells once Part 2 lands).

**Pros:** discoverable, scales (room for Shell/Model groups), zero architecture
change, pure `bindings.conf` work. **Cons:** one extra keypress to reach an
action via the menu (mitigated by keeping direct keys).

---

## Part 2 — Grouped ephemeral shells  (branch `feat/ephemeral-shells`)
Extend the existing **`claude-shell`** (today: opens a shell window, named
`sh:<dir-basename>`, **not** registered):

- Register the shell in the registry as an **ephemeral** record:
  `kind = shell`, `parent = <instance window_id>`, `cwd = <pwd>`,
  name = its pwd basename, **colour inherited from the parent instance**.
- This makes the shell show up **grouped under its instance** in `claude-ls`
  (indented) and lets the status bar render them together.
- **Reconcile** removes the ephemeral record when its window closes (already the
  mechanism for instances); optionally close child shells when the parent
  instance closes.
- Ephemeral shells are **excluded** from conversation flows (not "resumable", not
  snapshotted for `restore_on_boot`).
- Menu **Shell** group (Part 1): "New shell here" (`claude-shell`), "New shell in
  dir…" (`claude-shell -D`).
- Usage for the `!` case: when Claude suggests `! <interactive cmd>`, you run
  **`claude-shell`** (or pick it from the menu) → a pwd-labelled shell opens in
  the instance's group; run the command there.

### Schema change (handled by existing migration)
Adds two registry fields: **`kind`** (`instance` | `shell`) and **`parent`**
(parent `window_id`). That's **schema v3** — `cs_open`/`cs_migrate` already
upgrade v2→v3 record-by-record (backed up + validated), so existing registries
migrate automatically. `cs_rows` gains the two columns; consumers that don't care
ignore them.

### Visual grouping caveat (depends on Part 3)
Until the grouping model is chosen, grouping is **lightweight**: the registry
`parent` link + shared colour + window ordering (place a new shell right after
its instance) + indentation in `claude-ls`. If Part 3 later picks
"session-per-instance", ephemeral shells become real windows in the instance's
session and the grouping becomes native.

---

## Part 3 — Grouping architecture  (DEFERRED — "skip for now")
Decide later; documented here so Part 2 doesn't pre-commit:

- **A. Session per instance** — each instance is its own tmux *session*; its
  shells are windows in it. *True* taskbar groups (switch with the session
  chooser). **Big change**: registry, picker, navigation, the boot service all
  move from one `claude` session to many.
- **B. Grouped windows in one session** — keep one session; group via the
  registry `parent` link + naming/order/colour + a custom status-bar format.
  **Low-disruption**, "fake" grouping but visually close.

Part 2 ships with B-style lightweight grouping; revisit for a full decision.

---

## Branch breakdown (separate, as requested)
1. **`feat/fluent-menus`** — grouped drill-down menu refactor (+ optional status-bar polish). Self-contained; no schema change.
2. **`feat/ephemeral-shells`** — `claude-shell` registers grouped, pwd-labelled ephemeral shells; registry schema v3 (`kind`/`parent`); `claude-ls` grouped display; the Part-1 "Shell" menu group.
3. *(deferred)* grouping-architecture — after the Part-3 decision.
4. *(deferred)* auto-spawn-on-`!`-suggestion watcher — only if you later want it (transcript-tailing, best-effort).

Each branch: bats/integration tests, docs (`docs/index.html` + README + this plan
updated), one PR.

## Open questions
1. Should closing a parent instance also close its ephemeral shells, or leave
   them? (Proposed: leave them; they reconcile to closed when their own window
   dies.)
2. Status-bar restyle in Part 1, or keep it minimal and do styling in a later
   pass?
3. Confirm the menu group set + names above (Instances / Conversations / Shell /
   Model / Help).
