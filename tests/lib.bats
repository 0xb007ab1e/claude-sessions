#!/usr/bin/env bats
# Unit tests for lib.sh. Run: bats tests/   (install: apt install bats / brew install bats-core)
# Each test gets an isolated HOME/state and a non-existent session so no real
# tmux server is touched.

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

@test "cs_record_active keeps one active row per window id" {
  cs_record_active a 39 @1 /tmp/a
  cs_record_active b 40 @1 /tmp/b      # same window id supersedes
  run wc -l < "$(cs_registry)"
  [ "${output// /}" -eq 1 ]
}

@test "cs_reconcile closes rows whose window is gone" {
  cs_record_active a 39 @1 /tmp/a      # session doesn't exist -> no live windows
  cs_reconcile
  run awk -F'\t' '{print $7}' "$(cs_registry)"
  [ "$output" = closed ]
}

@test "cs_prune keeps newest N closed rows" {
  mkdir -p "$(cs_state_dir)"
  printf 'a\t39\t%s\t@1\t/a\t1\tclosed\t100\n' "$CLAUDE_TMUX_SESSION" >  "$(cs_registry)"
  printf 'b\t40\t%s\t@2\t/b\t1\tclosed\t200\n' "$CLAUDE_TMUX_SESSION" >> "$(cs_registry)"
  printf 'c\t41\t%s\t@3\t/c\t1\tclosed\t300\n' "$CLAUDE_TMUX_SESSION" >> "$(cs_registry)"
  cs_prune 2
  run cut -f1 "$(cs_registry)"
  [[ "$output" == *c* ]] && [[ "$output" == *b* ]] && [[ "$output" != *a* ]]
}
