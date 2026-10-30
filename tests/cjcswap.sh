#!/usr/bin/env bash
# tests/cjcswap.sh — exercises the cj-cswap CJ_CLAUDE shim with STUB cswap/claude
# on PATH that just log their argv. Asserts the credential-routing boundary:
#   cswap absent              -> exec claude "$@"                 (fail-open)
#   cswap present, no acct    -> exec cswap run -- "$@"           (dir map / default)
#   cswap present, acct pinned-> exec cswap run <acct> -- "$@"    (CJ_CSWAP_ACCT)
# No real cswap/claude needed.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SHIM="$REPO/cj-cswap"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/argv.log"

# Stub claude: always available via the WITH-cswap vs NO-cswap PATHs below.
mkdir -p "$WORK/bin" "$WORK/nocswap"
cat > "$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" > "$LOG"
EOF
cat > "$WORK/bin/cswap" <<EOF
#!/usr/bin/env bash
echo "cswap \$*" > "$LOG"
EOF
cp "$WORK/bin/claude" "$WORK/nocswap/claude"          # claude present, cswap NOT
chmod +x "$WORK/bin/claude" "$WORK/bin/cswap" "$WORK/nocswap/claude"

rc=0
assert() { # desc expected
  local got; got="$(cat "$LOG" 2>/dev/null || true)"
  if [ "$got" = "$2" ]; then echo "PASS [$1]"
  else echo "FAIL [$1]: got '$got' want '$2'"; rc=1; fi
}

# 1) cswap absent from PATH -> plain claude, args forwarded verbatim
: > "$LOG"
PATH="$WORK/nocswap:/usr/bin:/bin" CJ_CSWAP_ACCT="" bash "$SHIM" -m resume -c /x >/dev/null 2>&1 || true
assert "cswap absent -> exec claude" "claude -m resume -c /x"

# 2) cswap present, no account pin -> cswap run -- <args>
: > "$LOG"
PATH="$WORK/bin:/usr/bin:/bin" bash "$SHIM" -m resume -c /x >/dev/null 2>&1 || true
assert "cswap present, no acct -> cswap run -- args" "cswap run -- -m resume -c /x"

# 3) cswap present, CJ_CSWAP_ACCT pinned -> cswap run <acct> -- <args>
: > "$LOG"
PATH="$WORK/bin:/usr/bin:/bin" CJ_CSWAP_ACCT=2 bash "$SHIM" -m resume >/dev/null 2>&1 || true
assert "cswap present, acct pinned -> cswap run 2 -- args" "cswap run 2 -- -m resume"

exit $rc
