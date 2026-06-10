# Bash completion for the claude-sessions tools.
# Sourced from ~/.bashrc by install.sh. For zsh, run `autoload -U +X bashcompinit
# && bashcompinit` first, then source this file.

_cs_schemes='nato project random'
_cs_models='opus sonnet haiku'
_cs_efforts='low medium high xhigh max'

_cj_complete() {
  local cur prev; cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"
  case "$prev" in
    -a) COMPREPLY=($(compgen -W "$_cs_schemes" -- "$cur")); return ;;
    -M|--model)  COMPREPLY=($(compgen -W "$_cs_models" -- "$cur")); return ;;
    -E|--effort) COMPREPLY=($(compgen -W "$_cs_efforts" -- "$cur")); return ;;
  esac
  COMPREPLY=($(compgen -W "-a -n -M -E --auto --name --model --effort" -- "$cur"))
}
complete -F _cj_complete cj

_claude_new_complete() {
  local cur prev; cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"
  case "$prev" in
    -m) COMPREPLY=($(compgen -W "new resume continue" -- "$cur")); return ;;
    -a) COMPREPLY=($(compgen -W "$_cs_schemes" -- "$cur")); return ;;
    -c) COMPREPLY=($(compgen -d -- "$cur")); return ;;
    -M) COMPREPLY=($(compgen -W "$_cs_models" -- "$cur")); return ;;
    -E) COMPREPLY=($(compgen -W "$_cs_efforts" -- "$cur")); return ;;
  esac
  COMPREPLY=($(compgen -W "-m -c -n -a -i -M -E -D" -- "$cur"))
}
complete -F _claude_new_complete claude-new

_claude_ls_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "--reconcile-only --prune" -- "$cur"))
}
complete -F _claude_ls_complete claude-ls

_claude_session_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "-s -a -g -n -h" -- "$cur"))
}
complete -F _claude_session_complete claude-session

_claude_ask_complete() {
  local cur prev; cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"
  # First word after the command = subcommand.
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "run send wait close help" -- "$cur")); return
  fi
  case "${COMP_WORDS[1]}" in
    run)  COMPREPLY=($(compgen -W "-n -e -m -S -w -c -t -- -h" -- "$cur")) ;;
    send) COMPREPLY=($(compgen -W "-F" -- "$cur")) ;;
    wait) COMPREPLY=($(compgen -W "-t -c" -- "$cur")) ;;
  esac
}
complete -F _claude_ask_complete claude-ask

# Simple flag/no-arg completers for the rest.
complete -W "--if-enabled" claude-restore-all 2>/dev/null || true
