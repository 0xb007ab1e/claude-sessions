#!/usr/bin/env bash
# lib.sh — shared helpers for the claude-sessions tools: config, naming schemes,
# a color palette, and the active/closed instance registry. Sourced (not run) by
# cj, claude-session, claude-ls, claude-new, claude-restore.
#
# Registry: one TSV row per instance, columns:
#   1 name  2 color  3 session  4 window_id  5 cwd  6 started_epoch
#   7 status(active|closed)  8 ended_epoch

# --- locations ---------------------------------------------------------------
cs_session()     { echo "${CLAUDE_TMUX_SESSION:-claude}"; }
# Fixed at ~/.config so tmux's `source-file ~/.config/.../bindings.conf` (which
# cannot read $XDG_CONFIG_HOME) always finds the generated bindings.
cs_config_dir()  { echo "$HOME/.config/claude-sessions"; }
cs_config_file() { echo "$(cs_config_dir)/config"; }
cs_state_dir()   { echo "${XDG_STATE_HOME:-$HOME/.local/state}/claude-sessions"; }
cs_registry()    { echo "$(cs_state_dir)/registry.tsv"; }

# --- config: a simple "key = value" file (comments with #) -------------------
# cs_config_get KEY [DEFAULT]
cs_config_get() {
  local key="$1" def="${2:-}" f v
  f="$(cs_config_file)"
  [ -f "$f" ] || { printf '%s' "$def"; return; }
  v="$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$f" | tail -1)"
  v="${v%%#*}"                       # strip trailing comment
  v="${v#"${v%%[![:space:]]*}"}"     # ltrim
  v="${v%"${v##*[![:space:]]}"}"     # rtrim
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

# Resolve the naming scheme. Precedence: explicit arg > env > config > "nato".
cs_scheme() {
  local s="${1:-}"
  [ -n "$s" ] && { printf '%s' "$s"; return; }
  [ -n "${CLAUDE_NAME_SCHEME:-}" ] && { printf '%s' "$CLAUDE_NAME_SCHEME"; return; }
  cs_config_get name_scheme nato
}

# --- palettes (256-color codes shared by tmux `colourN` and ANSI 38;5;N) -----
CS_COLORS=(39 208 46 201 226 51 213 118 220 165 45 196 82 99 214 87)
CS_NATO=(alpha bravo charlie delta echo foxtrot golf hotel india juliet
         kilo lima mike november oscar papa quebec romeo sierra tango
         uniform victor whiskey xray yankee zulu)
CS_ADJ=(brave calm keen wise swift bright bold quiet sharp eager lucky nimble)
CS_NOUN=(otter finch lynx heron fox wren ibex hawk mole crane vole stoat)

cs_color_idx() { echo "${CS_COLORS[$(( ${1:-0} % ${#CS_COLORS[@]} ))]}"; }

# Stable color for a string (hash → palette index).
cs_color_hash() {
  local s="$1" h=0 i c
  for (( i=0; i<${#s}; i++ )); do printf -v c '%d' "'${s:$i:1}"; h=$(( (h*31 + c) % 100003 )); done
  cs_color_idx "$h"
}

# Names already taken: live window names + active registry entries.
cs_used_names() {
  tmux list-windows -t "$(cs_session)" -F '#W' 2>/dev/null
  local reg; reg="$(cs_registry)"
  [ -f "$reg" ] && awk -F'\t' '$7=="active"{print $2}' "$reg"
}

# Allocate "name<TAB>color" for a scheme + cwd, avoiding collisions.
cs_alloc_name() {
  local scheme="$1" cwd="${2:-$PWD}" used name="" color n i k
  used="$(cs_used_names | sort -u)"
  _taken() { grep -qxF -- "$1" <<<"$used"; }
  case "$scheme" in
    project)
      local base; base="$(basename "$cwd")"; base="${base//[^a-zA-Z0-9_-]/}"; base="${base:-claude}"
      i=1; while _taken "${base}-${i}"; do i=$((i+1)); done
      name="${base}-${i}"; color="$(cs_color_hash "$name")" ;;
    random)
      local tries=0
      while :; do
        name="${CS_ADJ[RANDOM % ${#CS_ADJ[@]}]}-${CS_NOUN[RANDOM % ${#CS_NOUN[@]}]}"
        _taken "$name" || break
        tries=$((tries+1)); [ "$tries" -gt 200 ] && { name="${name}-${RANDOM}"; break; }
      done
      color="$(cs_color_hash "$name")" ;;
    nato|*)
      i=0
      for n in "${CS_NATO[@]}"; do _taken "$n" || { name="$n"; break; }; i=$((i+1)); done
      if [ -z "$name" ]; then
        k=2
        while [ -z "$name" ]; do
          for n in "${CS_NATO[@]}"; do _taken "${n}${k}" || { name="${n}${k}"; break; }; done
          k=$((k+1))
        done
      fi
      color="$(cs_color_idx "$i")" ;;
  esac
  printf '%s\t%s\n' "$name" "$color"
}

# Apply a name + color to a window target (e.g. "claude:@5" or "claude:3").
cs_apply_window() {
  local target="$1" name="$2" color="$3"
  tmux rename-window -t "$target" "$name" 2>/dev/null || true
  tmux set-window-option -t "$target" window-status-style "fg=colour${color}" 2>/dev/null || true
  tmux set-window-option -t "$target" window-status-current-style "fg=colour${color},bold,reverse" 2>/dev/null || true
}

# Append an active row, keeping at most one active row per window id (a reused
# window supersedes its previous active row). cs_record_active NAME COLOR WID CWD
# Column 9 (transcript) starts empty and is filled later by cs_link_transcripts.
cs_record_active() {
  local reg tmp; reg="$(cs_registry)"; mkdir -p "$(cs_state_dir)"
  if [ -f "$reg" ]; then
    tmp="$(mktemp)"
    awk -F'\t' -v wid="$3" '!($7=="active" && $4==wid)' "$reg" > "$tmp" && mv "$tmp" "$reg"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$(cs_session)" "$3" "$4" "$(date +%s)" active "" "" >> "$reg"
}

# Claude's transcript directory for a cwd (non-alphanumerics → '-', matching
# Claude Code's project-dir encoding). Honors $CLAUDE_CONFIG_DIR.
cs_project_dir() {
  printf '%s/projects/%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
    "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
}

# Best-effort: the transcript (session) id for an instance — the newest
# *.jsonl in the cwd's project dir modified at/after the start time.
# cs_find_transcript CWD STARTED_EPOCH  ->  uuid or empty
cs_find_transcript() {
  local d f; d="$(cs_project_dir "$1")"
  [ -d "$d" ] || return 0
  f="$(find "$d" -maxdepth 1 -name '*.jsonl' -newermt "@$(( ${2:-0} - 2 ))" \
         -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$f" ] && basename "$f" .jsonl || true
}

# Fill the transcript id (column 9) for active rows that don't have one yet.
cs_link_transcripts() {
  local reg tmp name color sess wid cwd started status ended transcript
  reg="$(cs_registry)"; [ -f "$reg" ] || return 0
  tmp="$(mktemp)"
  while IFS=$'\t' read -r name color sess wid cwd started status ended transcript; do
    if [ "$status" = active ] && [ -z "$transcript" ]; then
      transcript="$(cs_find_transcript "$cwd" "$started")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$color" "$sess" "$wid" "$cwd" "$started" "$status" "$ended" "$transcript"
  done < "$reg" > "$tmp" && mv "$tmp" "$reg"
}

# Mark active rows closed when their window no longer exists.
cs_reconcile() {
  local reg s live now tmp
  reg="$(cs_registry)"; [ -f "$reg" ] || return 0
  s="$(cs_session)"
  live=" $(tmux list-windows -t "$s" -F '#{window_id}' 2>/dev/null | tr '\n' ' ') "
  now="$(date +%s)"
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v live="$live" -v now="$now" '
    $7=="active" && index(live, " " $4 " ")==0 { $7="closed"; $8=now }
    { print }
  ' "$reg" > "$tmp" && mv "$tmp" "$reg"
  cs_link_transcripts   # capture transcript ids for still-active instances
}

# Rename a window and update its active registry row. cs_set_name WID NEWNAME
cs_set_name() {
  local wid="$1" newname="$2" reg tmp
  tmux rename-window -t "$(cs_session):$wid" "$newname" 2>/dev/null || true
  reg="$(cs_registry)"; [ -f "$reg" ] || return 0
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v wid="$wid" -v n="$newname" \
    '$4==wid && $7=="active"{$1=n} {print}' "$reg" > "$tmp" && mv "$tmp" "$reg"
}

# Keep all active rows + the most recently-closed N (by end time). cs_prune [N]
cs_prune() {
  local keep="${1:-50}" reg tmp; reg="$(cs_registry)"; [ -f "$reg" ] || return 0
  tmp="$(mktemp)"
  { awk -F'\t' '$7=="active"' "$reg"
    awk -F'\t' '$7=="closed"' "$reg" | sort -t"$(printf '\t')" -k8,8nr | head -n "$keep"
  } > "$tmp" && mv "$tmp" "$reg"
}
