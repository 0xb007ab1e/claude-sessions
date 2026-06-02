#!/usr/bin/env bash
# lib.sh — shared helpers for the claude-sessions tools: config, naming schemes,
# a color palette, live status, and the active/closed instance registry.
# Sourced (not run) by the claude-* tools.
#
# Registry: JSONL (one JSON object per line) at registry.jsonl. Each record:
#   {v, name, color, session, window_id, cwd, started, status, ended,
#    transcript, model, effort}
#   v        = schema version (CS_SCHEMA_VERSION)
#   status   = "active" | "closed";  ended/transcript/model/effort may be null
# Reads/writes go through jq (correct escaping). cs_rows renders records back to
# the legacy tab-separated column order (name,color,session,window_id,cwd,
# started,status,ended,transcript,model,effort) for awk/cut-based consumers.
#
# Migration: the on-disk version is checked on first access (cs_open). An older
# registry (legacy v1 TSV at registry.tsv, or JSONL with v<current) is backed up,
# upgraded record-by-record, and validated against the backup, all under flock.

CS_SCHEMA_VERSION=2

# --- locations ---------------------------------------------------------------
cs_session()          { echo "${CLAUDE_TMUX_SESSION:-claude}"; }
# Fixed at ~/.config so tmux's `source-file ~/.config/.../bindings.conf` (which
# cannot read $XDG_CONFIG_HOME) always finds the generated bindings.
cs_config_dir()       { echo "$HOME/.config/claude-sessions"; }
cs_config_file()      { echo "$(cs_config_dir)/config"; }
cs_state_dir()        { echo "${XDG_STATE_HOME:-$HOME/.local/state}/claude-sessions"; }
cs_registry()         { echo "$(cs_state_dir)/registry.jsonl"; }
cs_registry_legacy()  { echo "$(cs_state_dir)/registry.tsv"; }   # pre-v2 format

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

# Set a config key (update in place, or append). cs_config_set KEY VALUE
cs_config_set() {
  local key="$1" val="$2" f tmp; f="$(cs_config_file)"
  mkdir -p "$(cs_config_dir)"; touch "$f"
  if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$f"; then
    tmp="$(mktemp)"
    sed "s#^[[:space:]]*$key[[:space:]]*=.*#$key = $val#" "$f" > "$tmp" && mv "$tmp" "$f"
  else
    printf '%s = %s\n' "$key" "$val" >> "$f"
  fi
}

# Path helpers for the directory picker's floor.
# cs_dir_within ROOT PATH -> 0 if PATH is ROOT or below it.
cs_dir_within() { case "$2/" in "$1/"*) return 0 ;; *) return 1 ;; esac; }
# cs_dir_rel ROOT PATH -> PATH relative to ROOT ("." when equal).
cs_dir_rel() { local r="$1" p="$2"; [ "$p" = "$r" ] && { printf '.'; return; }; p="${p#"$r"/}"; printf '%s' "$p"; }
# Preferred picker start: $PWD if within ROOT (echo it, return 0); otherwise echo
# ROOT and return 1 so the caller can warn + reprompt.  cs_pick_start ROOT
cs_pick_start() {
  local root="$1" here; here="$(pwd -P 2>/dev/null)" || here="$root"
  if cs_dir_within "$root" "$here"; then printf '%s' "$here"; return 0
  else printf '%s' "$root"; return 1; fi
}

# Resolve the naming scheme. Precedence: explicit arg > env > config > "nato".
cs_scheme() {
  local s="${1:-}"
  [ -n "$s" ] && { printf '%s' "$s"; return; }
  [ -n "${CLAUDE_NAME_SCHEME:-}" ] && { printf '%s' "$CLAUDE_NAME_SCHEME"; return; }
  cs_config_get name_scheme nato
}

# Pick a directory by walking the tree one level at a time, echoing the chosen
# absolute path. Entries are shown RELATIVE to the root (search_dir). Navigation
# is floored at the root: you cannot go above it unless `allow_dir_escape = true`
# in config, in which case the in-picker key Alt-u (and ".." at the root) ascends
# past it. Folders open on Enter; choosing a file selects its parent folder; the
# "[ choose THIS folder ]" row selects the current directory.
# cs_pick_dir [default-start-dir]
cs_pick_dir() {
  local root escape cur warn=""
  root="$(cs_config_get search_dir "$HOME")"; root="${root/#\~/$HOME}"
  root="$(cd "$root" 2>/dev/null && pwd -P)" || root="$HOME"
  escape="$(cs_config_get allow_dir_escape false)"
  # $PWD is the preferred start; if it's outside the root, warn and start at root.
  if cur="$(cs_pick_start "$root")"; then warn=""
  else warn="current directory is outside the picker root ($root) — starting at root"
       printf 'claude: %s\n' "$warn" >&2; fi

  if ! command -v fzf >/dev/null 2>&1; then          # fallback: type a path
    local _d
    bind 'set completion-ignore-case on' 2>/dev/null || true
    read -e -i "$cur" -r -p "directory (Tab completes): " _d || _d="$cur"
    _d="${_d/#\~/$HOME}"; _d="$(cd "$_d" 2>/dev/null && pwd -P)" || _d="$cur"
    if [ "$escape" != true ] && ! cs_dir_within "$root" "$_d"; then _d="$root"; fi
    printf '%s' "$_d"; return
  fi

  local CHOOSE="[ choose THIS folder ]" UP=".. (up)" lister relcur list hdr out key sel
  while :; do
    if   command -v fd     >/dev/null 2>&1; then lister=(fd -d1 -H -E .git -E node_modules . "$cur")
    elif command -v fdfind >/dev/null 2>&1; then lister=(fdfind -d1 -H -E .git -E node_modules . "$cur")
    else lister=(find "$cur" -mindepth 1 -maxdepth 1 -not -name .git -not -name node_modules); fi
    relcur="$(cs_dir_rel "$root" "$cur")"
    list="$( {
        printf '%s\n' "$CHOOSE"
        if [ "$cur" != "$root" ] || [ "$escape" = true ]; then printf '%s\n' "$UP"; fi
        "${lister[@]}" 2>/dev/null | while IFS= read -r p; do
          p="${p%/}"                       # fd appends '/' to dirs; normalize
          if [ -d "$p" ]; then printf '%s/\n' "$(cs_dir_rel "$root" "$p")"
          else printf '%s\n' "$(cs_dir_rel "$root" "$p")"; fi
        done | LC_ALL=C sort
      } )"
    hdr="root: ${root}    here: ${relcur}    Enter: open/select · Alt-u: above root$([ "$escape" = true ] && echo ' (on)' || echo ' (locked)')"
    [ -n "$warn" ] && hdr="⚠ ${warn}"$'\n'"$hdr"   # banner on the first render
    out="$(printf '%s\n' "$list" | fzf --expect=alt-u --prompt="dir> " --height=90% \
            --reverse --no-multi --header="$hdr" 2>/dev/null)" || return 0
    warn=""   # show the warning only once
    key="$(printf '%s\n' "$out" | sed -n 1p)"; sel="$(printf '%s\n' "$out" | sed -n 2p)"
    [ -z "$key" ] && [ -z "$sel" ] && return 0       # ESC cancels
    if [ "$key" = alt-u ]; then                       # override: ascend past root
      [ "$escape" = true ] && cur="$(dirname "$cur")"; continue
    fi
    case "$sel" in
      "$CHOOSE") printf '%s' "$cur"; return ;;
      "$UP")
        if [ "$cur" != "$root" ]; then cur="$(dirname "$cur")"
        elif [ "$escape" = true ]; then cur="$(dirname "$cur")"; fi ;;
      "") : ;;
      *)  # entries are immediate children of cur; reconstruct from cur + basename
          # (robust whether displayed relative to root or absolute when above it)
        local name="${sel%/}"; name="${name##*/}"; local abs="$cur/$name"
        if   [ -d "$abs" ]; then cur="$abs"
        elif [ -f "$abs" ]; then printf '%s' "$cur"; return
        fi ;;
    esac
  done
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

# =====================  registry: JSONL store via jq  ========================

# Render the registry as legacy tab-separated rows, canonical column order, so
# awk/cut-based consumers are unchanged. Empty fields preserved; empty if none.
cs_rows() {
  cs_open
  local reg; reg="$(cs_registry)"; [ -s "$reg" ] || return 0
  jq -r 'select(type=="object")
         | [ .name, .color, .session, .window_id, .cwd, (.started|tostring),
             .status, (.ended|if .==null then "" else tostring end),
             (.transcript//""), (.model//""), (.effort//"") ] | @tsv' \
     "$reg" 2>/dev/null
}

# Read field N (1-based, tab-delimited, preserves empty fields) from a row that
# cs_rows produced. cs_field N "row"
cs_field() { cut -f"$1" <<<"$2"; }

# Ensure the registry exists and is at the current schema version (lazy migrate).
cs_open() {
  local reg legacy lock; reg="$(cs_registry)"; legacy="$(cs_registry_legacy)"
  mkdir -p "$(cs_state_dir)"
  if [ -f "$reg" ]; then
    # All records current (empty file slurps to [] -> all() is true)?
    jq -se 'all(.[]; (.v//0)=='"$CS_SCHEMA_VERSION"')' "$reg" >/dev/null 2>&1 && return 0
  elif [ ! -s "$legacy" ]; then
    : > "$reg"; return 0          # nothing anywhere -> fresh empty registry
  fi
  lock="$(cs_state_dir)/.registry.lock"
  { exec 9>"$lock"; flock 9 2>/dev/null || true; cs_migrate; flock -u 9 2>/dev/null || true; } 9>"$lock"
}

# Back up, upgrade record-by-record to CS_SCHEMA_VERSION, validate vs. backup.
cs_migrate() {
  local reg legacy ts bak src tmp
  reg="$(cs_registry)"; legacy="$(cs_registry_legacy)"; ts="$(date +%s)"
  if [ -f "$reg" ] && [ -s "$reg" ]; then
    src="$reg";    bak="$reg.bak.$ts"
  elif [ -s "$legacy" ]; then
    src="$legacy"; bak="$legacy.bak.$ts"
  else
    : > "$reg"; return 0
  fi
  cp -p "$src" "$bak"
  tmp="$(mktemp)"

  if [ "$src" = "$legacy" ]; then
    # Legacy v1 TSV (11 cols) -> JSONL v2, one record per non-empty line.
    local line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      jq -cn --argjson v "$CS_SCHEMA_VERSION" \
        --arg name "$(cut -f1 <<<"$line")"   --arg color "$(cut -f2 <<<"$line")" \
        --arg session "$(cut -f3 <<<"$line")" --arg wid "$(cut -f4 <<<"$line")" \
        --arg cwd "$(cut -f5 <<<"$line")"    --arg started "$(cut -f6 <<<"$line")" \
        --arg status "$(cut -f7 <<<"$line")" --arg ended "$(cut -f8 <<<"$line")" \
        --arg transcript "$(cut -f9 <<<"$line")" --arg model "$(cut -f10 <<<"$line")" \
        --arg effort "$(cut -f11 <<<"$line")" \
        '{v:$v,name:$name,color:$color,session:$session,window_id:$wid,cwd:$cwd,
          started:($started|tonumber? // 0),status:$status,
          ended:($ended|if .=="" then null else (tonumber? // null) end),
          transcript:($transcript|select(.!="")//null),
          model:($model|select(.!="")//null),
          effort:($effort|select(.!="")//null)}'
    done < "$src" > "$tmp"
  else
    # JSONL upgrade: stamp current version, ensure all fields exist.
    jq -c --argjson v "$CS_SCHEMA_VERSION" \
      '{v:$v, name, color, session, window_id, cwd, started, status,
        ended:(.ended//null), transcript:(.transcript//null),
        model:(.model//null), effort:(.effort//null)}' "$src" > "$tmp"
  fi

  # Validate: every record is at the current version, and the (name|window_id|
  # started) key set + record count match the backup — no records lost/altered.
  local ok=1
  jq -se 'all(.[]; .v=='"$CS_SCHEMA_VERSION"')' "$tmp" >/dev/null 2>&1 || ok=0
  local newn oldn
  newn="$(grep -c . "$tmp" 2>/dev/null || echo 0)"
  if [ "$src" = "$legacy" ]; then oldn="$(grep -c . "$bak" 2>/dev/null || echo 0)"
  else oldn="$(grep -c . "$bak" 2>/dev/null || echo 0)"; fi
  [ "$newn" = "$oldn" ] || ok=0
  local newk oldk
  newk="$(jq -r '[.name,.window_id,(.started|tostring)]|@tsv' "$tmp" 2>/dev/null | sort)"
  if [ "$src" = "$legacy" ]; then
    oldk="$(awk -F'\t' 'NF{print $1"\t"$4"\t"$6}' "$bak" | sort)"
  else
    oldk="$(jq -r '[.name,.window_id,(.started|tostring)]|@tsv' "$bak" 2>/dev/null | sort)"
  fi
  [ "$newk" = "$oldk" ] || ok=0

  if [ "$ok" = 1 ]; then
    mv "$tmp" "$reg"
    : > "$(cs_state_dir)/.migrated"   # marker: a backup exists to offer removing
    echo "claude-sessions: migrated registry to v$CS_SCHEMA_VERSION (backup: $bak)" >&2
  else
    rm -f "$tmp"
    echo "claude-sessions: registry migration validation FAILED — left unchanged (backup: $bak)" >&2
    return 1
  fi
}

# Remove migration backups after a successful migration. cs_clean_backups
cs_clean_backups() {
  local d; d="$(cs_state_dir)"
  rm -f "$d"/registry.jsonl.bak.* "$d"/registry.tsv.bak.* 2>/dev/null || true
  rm -f "$d/.migrated" 2>/dev/null || true
}

# Names already taken: live window names + active registry entries.
cs_used_names() {
  tmux list-windows -t "$(cs_session)" -F '#W' 2>/dev/null
  cs_open; local reg; reg="$(cs_registry)"
  [ -s "$reg" ] && jq -r 'select(.status=="active") | .name' "$reg" 2>/dev/null
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

# Append an active record, superseding any existing active record for the same
# window id (a reused window replaces its previous active row).
#   cs_record_active NAME COLOR WID CWD [TRANSCRIPT] [MODEL] [EFFORT]
cs_record_active() {
  cs_open
  local reg tmp; reg="$(cs_registry)"; mkdir -p "$(cs_state_dir)"; tmp="$(mktemp)"
  { [ -s "$reg" ] && jq -c --arg w "$3" 'select(.window_id!=$w or .status!="active")' "$reg" 2>/dev/null
    jq -cn --argjson v "$CS_SCHEMA_VERSION" \
      --arg name "$1" --arg color "$2" --arg session "$(cs_session)" --arg wid "$3" \
      --arg cwd "$4" --argjson started "$(date +%s)" \
      --arg transcript "${5:-}" --arg model "${6:-}" --arg effort "${7:-}" \
      '{v:$v,name:$name,color:$color,session:$session,window_id:$wid,cwd:$cwd,
        started:$started,status:"active",ended:null,
        transcript:($transcript|select(.!="")//null),
        model:($model|select(.!="")//null),
        effort:($effort|select(.!="")//null)}'
  } > "$tmp" && mv "$tmp" "$reg"
}

# Claude's transcript directory for a cwd (non-alphanumerics → '-', matching
# Claude Code's project-dir encoding). Honors $CLAUDE_CONFIG_DIR.
cs_project_dir() {
  printf '%s/projects/%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
    "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
}

# Best-effort: the transcript id for an instance — the newest *.jsonl in the
# cwd's project dir modified at/after the start time.
# cs_find_transcript CWD STARTED_EPOCH  ->  uuid or empty
cs_find_transcript() {
  local d f; d="$(cs_project_dir "$1")"
  [ -d "$d" ] || return 0
  f="$(find "$d" -maxdepth 1 -name '*.jsonl' -newermt "@$(( ${2:-0} - 2 ))" \
         -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$f" ] && basename "$f" .jsonl || true
}

# Fill the transcript id for active records that don't have one yet.
cs_link_transcripts() {
  local reg tmp wid cwd started newt; reg="$(cs_registry)"; [ -s "$reg" ] || return 0
  while IFS=$'\t' read -r wid cwd started; do
    [ -n "$wid" ] || continue
    newt="$(cs_find_transcript "$cwd" "$started")"; [ -n "$newt" ] || continue
    tmp="$(mktemp)"
    jq -c --arg w "$wid" --arg t "$newt" \
      'if .window_id==$w and .status=="active" and (.transcript==null or .transcript=="")
       then .transcript=$t else . end' "$reg" > "$tmp" && mv "$tmp" "$reg"
  done < <(jq -r 'select(.status=="active" and (.transcript==null or .transcript==""))
                  | [.window_id,.cwd,(.started|tostring)] | @tsv' "$reg" 2>/dev/null)
}

# --- per-instance live status (written by claude-hook, read by claude-ls/bar) -
#   working | idle | needs-approval   (idle = finished a turn, awaiting input)
cs_status_dir()   { echo "$(cs_state_dir)/status"; }
_cs_status_file() { echo "$(cs_status_dir)/$(printf '%s' "$1" | tr -c 'A-Za-z0-9@_-' '_')"; }
cs_set_status()   { mkdir -p "$(cs_status_dir)"; printf '%s\t%s\n' "$2" "$(date +%s)" > "$(_cs_status_file "$1")"; }
cs_get_status()   { local f; f="$(_cs_status_file "$1")"; [ -f "$f" ] && cut -f1 "$f" || true; }
cs_clear_status() { rm -f "$(_cs_status_file "$1")" 2>/dev/null || true; }

# Mark active records closed when their window no longer exists, then link ids.
cs_reconcile() {
  cs_open
  local reg tmp live now; reg="$(cs_registry)"; [ -s "$reg" ] || return 0
  live="$(tmux list-windows -t "$(cs_session)" -F '#{window_id}' 2>/dev/null | jq -R . | jq -cs . 2>/dev/null)"
  [ -n "$live" ] || live='[]'
  now="$(date +%s)"; tmp="$(mktemp)"
  jq -c --argjson live "$live" --argjson now "$now" \
    'if .status=="active" and (([.window_id] - $live) | length > 0)
     then .status="closed" | .ended=$now else . end' "$reg" > "$tmp" && mv "$tmp" "$reg"
  cs_link_transcripts
}

# Rename a window and update its active registry record. cs_set_name WID NEWNAME
cs_set_name() {
  cs_open
  tmux rename-window -t "$(cs_session):$1" "$2" 2>/dev/null || true
  local reg tmp; reg="$(cs_registry)"; [ -s "$reg" ] || return 0
  tmp="$(mktemp)"
  jq -c --arg w "$1" --arg n "$2" \
    'if .window_id==$w and .status=="active" then .name=$n else . end' "$reg" > "$tmp" && mv "$tmp" "$reg"
}

# Keep all active records + the most recently-closed N (by end time). cs_prune [N]
cs_prune() {
  cs_open
  local keep="${1:-50}" reg tmp; reg="$(cs_registry)"; [ -s "$reg" ] || return 0
  tmp="$(mktemp)"
  { jq -c 'select(.status=="active")' "$reg"
    jq -c 'select(.status=="closed")' "$reg" \
      | jq -s -c --argjson k "$keep" 'sort_by(.ended // 0) | reverse | .[:$k] | .[]'
  } > "$tmp" && mv "$tmp" "$reg"
}
