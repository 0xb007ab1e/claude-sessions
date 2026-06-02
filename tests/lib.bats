#!/usr/bin/env bats
# Unit tests for lib.sh. Run: bats tests/   (install: apt install bats / brew install bats-core)
# Each test gets an isolated HOME/state and a non-existent session so no real
# tmux server is touched. The registry is JSONL (v2); cs_rows renders it back to
# the legacy tab-separated columns the assertions use.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/claude-sessions"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CLAUDE_TMUX_SESSION="cs_test_nope_$$"
  unset CLAUDE_NAME_SCHEME
  source "$BATS_TEST_DIRNAME/../lib.sh"
}

@test "cs_config_get returns default when unset" {
  run cs_config_get missing fallback
  [ "$output" = fallback ]
}

@test "cs_config_get reads a value and ignores comments" {
  printf 'name_scheme = random   # inline comment\n' > "$HOME/.config/claude-sessions/config"
  run cs_config_get name_scheme nato
  [ "$output" = random ]
}

@test "cs_scheme precedence: env beats config" {
  printf 'name_scheme = project\n' > "$HOME/.config/claude-sessions/config"
  CLAUDE_NAME_SCHEME=random run cs_scheme
  [ "$output" = random ]
}

@test "cs_scheme falls back to nato" {
  run cs_scheme
  [ "$output" = nato ]
}

@test "cs_color_idx is stable and wraps" {
  [ "$(cs_color_idx 0)" = "$(cs_color_idx 16)" ]
}

@test "cs_color_hash is deterministic" {
  [ "$(cs_color_hash foo)" = "$(cs_color_hash foo)" ]
}

@test "cs_alloc_name nato yields alpha first" {
  cs_used_names() { :; }            # nothing taken
  run cs_alloc_name nato /tmp/x
  [[ "$output" == alpha$'\t'* ]]
}

@test "cs_alloc_name nato skips taken names" {
  cs_used_names() { printf 'alpha\nbravo\n'; }
  run cs_alloc_name nato /tmp/x
  [[ "$output" == charlie$'\t'* ]]
}

@test "cs_alloc_name project uses cwd basename" {
  cs_used_names() { :; }
  run cs_alloc_name project /tmp/myproj
  [[ "$output" == myproj-1$'\t'* ]]
}

@test "registry is JSONL with a schema version" {
  cs_record_active a 39 @1 /tmp/a
  [ "$(jq -r .v "$(cs_registry)")" = "$CS_SCHEMA_VERSION" ]
  jq -e . "$(cs_registry)" >/dev/null     # each line is valid JSON
}

@test "cs_record_active keeps one active row per window id" {
  cs_record_active a 39 @1 /tmp/a
  cs_record_active b 40 @1 /tmp/b      # same window id supersedes
  [ "$(cs_rows | wc -l)" -eq 1 ]
  [ "$(cs_field 1 "$(cs_rows)")" = b ]
}

@test "cs_record_active escapes special chars in cwd" {
  cs_record_active a 39 @1 "/tmp/p q'\"x"
  [ "$(cs_field 5 "$(cs_rows)")" = "/tmp/p q'\"x" ]
}

@test "cs_reconcile closes rows whose window is gone" {
  cs_record_active a 39 @1 /tmp/a      # session doesn't exist -> no live windows
  cs_reconcile
  [ "$(cs_rows | cut -f7)" = closed ]
}

@test "cs_prune keeps newest N closed rows" {
  reg="$(cs_registry)"; mkdir -p "$(cs_state_dir)"
  for ne in a:100 b:200 c:300; do
    jq -cn --arg n "${ne%:*}" --argjson e "${ne#*:}" --argjson v "$CS_SCHEMA_VERSION" \
      '{v:$v,name:$n,color:"39",session:"x",window_id:("@"+$n),cwd:"/x",started:1,
        status:"closed",ended:$e,transcript:null,model:null,effort:null}'
  done > "$reg"
  cs_prune 2
  out="$(cs_rows | cut -f1)"
  [[ "$out" == *c* ]] && [[ "$out" == *b* ]] && [[ "$out" != *a* ]]
}

@test "cs_record_active stores model and effort" {
  cs_record_active a 39 @1 /tmp/a "" opus high
  row="$(cs_rows)"
  [ "$(cs_field 10 "$row")" = opus ]
  [ "$(cs_field 11 "$row")" = high ]
}

@test "cs_link_transcripts preserves model/effort" {
  cs_record_active a 39 @1 /tmp/a "" opus high   # empty transcript
  cs_find_transcript() { echo "FAKEUUID"; }       # stub so a transcript is linked
  cs_link_transcripts
  row="$(cs_rows)"
  [ "$(cs_field 9  "$row")" = FAKEUUID ]
  [ "$(cs_field 10 "$row")" = opus ]
  [ "$(cs_field 11 "$row")" = high ]
}

@test "cs_open migrates legacy v1 TSV to JSONL (current version, with backup)" {
  mkdir -p "$(cs_state_dir)"
  printf 'a\t39\t%s\t@1\t/tmp/proj one\t1000\tactive\t\t\tsonnet\thigh\n' \
    "$CLAUDE_TMUX_SESSION" > "$(cs_registry_legacy)"
  cs_open
  [ -s "$(cs_registry)" ]                                   # jsonl created
  [ "$(jq -r .v "$(cs_registry)")" = "$CS_SCHEMA_VERSION" ] # at current version
  [ "$(cs_field 5 "$(cs_rows)")" = "/tmp/proj one" ]        # data preserved
  [ "$(jq -r .kind "$(cs_registry)")" = instance ]          # legacy rows -> instance
  ls "$(cs_state_dir)"/registry.tsv.bak.* >/dev/null 2>&1   # backup made
}

@test "cs_record_active records kind=shell + parent (ephemeral shell)" {
  cs_record_active alpha 39 @1 /tmp/a                       # default -> instance
  cs_record_active sh:a 39 @2 /tmp/a "" "" "" shell @1      # ephemeral shell
  ish="$(cs_rows | awk -F'\t' '$4=="@2"')"
  [ "$(cs_field 12 "$ish")" = shell ]
  [ "$(cs_field 13 "$ish")" = @1 ]
  inst="$(cs_rows | awk -F'\t' '$4=="@1"')"
  [ "$(cs_field 12 "$inst")" = instance ]                  # default kind
}

@test "cs_open migrates v2 JSONL to v3 (adds kind/parent)" {
  mkdir -p "$(cs_state_dir)"
  printf '{"v":2,"name":"old","color":"39","session":"%s","window_id":"@1","cwd":"/tmp/o","started":1,"status":"active","ended":null,"transcript":null,"model":null,"effort":null}\n' \
    "$CLAUDE_TMUX_SESSION" > "$(cs_registry)"
  cs_open
  [ "$(jq -r .v "$(cs_registry)")" = "$CS_SCHEMA_VERSION" ]
  [ "$(jq -r .kind "$(cs_registry)")" = instance ]
  [ "$(jq -r .parent "$(cs_registry)")" = null ]
}

@test "cs_config_set updates existing and appends missing keys" {
  printf 'name_scheme = nato\n' > "$HOME/.config/claude-sessions/config"
  cs_config_set name_scheme random          # update in place
  cs_config_set ntfy_topic abc123           # append
  [ "$(cs_config_get name_scheme nato)" = random ]
  [ "$(cs_config_get ntfy_topic '')" = abc123 ]
}

@test "cs_dir_within: floor boundary" {
  cs_dir_within /a/b /a/b           # equal -> inside
  cs_dir_within /a/b /a/b/c/d       # below  -> inside
  ! cs_dir_within /a/b /a           # above  -> outside
  ! cs_dir_within /a/b /a/bc        # sibling prefix -> outside
}

@test "cs_dir_rel: path relative to root" {
  [ "$(cs_dir_rel /a/b /a/b)"     = "." ]
  [ "$(cs_dir_rel /a/b /a/b/c)"   = "c" ]
  [ "$(cs_dir_rel /a/b /a/b/c/d)" = "c/d" ]
}

@test "cs_pick_start precedence: PWD > caller default > root" {
  mkdir -p "$BATS_TEST_TMPDIR/r/a" "$BATS_TEST_TMPDIR/r/b"
  local r; r="$(cd "$BATS_TEST_TMPDIR/r" && pwd -P)"
  cd "$r/a"; run cs_pick_start "$r" "$r/b"
  [ "$status" -eq 0 ]; [ "$output" = "$r/a" ]        # PWD under root wins
  cd /;      run cs_pick_start "$r" "$r/b"
  [ "$status" -eq 0 ]; [ "$output" = "$r/b" ]        # PWD outside -> caller default (under root)
  cd /;      run cs_pick_start "$r" /nonexistent-xyz
  [ "$status" -eq 1 ]; [ "$output" = "$r" ]          # neither under root -> root (warn)
  cd /;      run cs_pick_start "$r"
  [ "$status" -eq 1 ]; [ "$output" = "$r" ]          # no default, PWD outside -> root (warn)
}

@test "cs_reconcile sweeps status files for dead windows" {
  cs_set_status @1 working
  cs_set_status @99 idle
  cs_record_active a 39 @1 /tmp/a          # session doesn't exist -> no live windows
  cs_reconcile
  [ ! -e "$(cs_status_dir)/@1" ]           # both swept
  [ ! -e "$(cs_status_dir)/@99" ]
}
