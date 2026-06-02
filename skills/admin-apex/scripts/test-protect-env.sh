#!/usr/bin/env bash
# Purpose: fixtures for skills/apex/scripts/protect-env-hook.sh. Locks the
#          deny/allow decisions the hook returns - now relied on for the Read
#          tool too (settings.json PreToolUse:Read), so a regression that
#          fail-OPENED a credential read must trip the suite.
# Spec: CLAUDE.md Security Non-Negotiable ("Never read/modify .env* files");
#       skills/apex/scripts/protect-env-hook.sh header.
#
# The hook is tool-agnostic (keys only on tool_input.file_path / notebook_path),
# so one fixture set covers every wired matcher (Edit|Write|MultiEdit|NotebookEdit
# AND Read). Kept separate from test-apex-scripts.sh (400-line file-health cap),
# which invokes this one and folds the result. Also runnable standalone.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
HOOK="$REPO_ROOT/skills/apex/scripts/protect-env-hook.sh"
pass=0
failed=0

# Feed a PreToolUse event JSON (file_path key) and print the permissionDecision.
decide() {  # file_path
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1" \
    | bash "$HOOK" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])" 2>/dev/null
}

check() {  # label file_path expected
  local got; got=$(decide "$2")
  if [[ "$got" == "$3" ]]; then
    echo "PASS $1 ($got)"; pass=$((pass + 1))
  else
    { echo "FAIL $1"; echo "    file=$2 expected=$3 got=$got"; } >&2
    failed=$((failed + 1))
  fi
}

check ".env read -> deny"              "/proj/.env"               deny
check ".env.local read -> deny"        "/proj/.env.local"         deny
check ".env.example read -> allow"     "/proj/.env.example"       allow
check ".env.template read -> allow"    "/proj/config/.env.template" allow
check "credentials.json -> deny"       "/proj/credentials.json"   deny
check "service-account.json -> deny"   "/proj/service-account.json" deny
check ".npmrc -> deny"                 "/proj/.npmrc"             deny
check "normal source file -> allow"    "/proj/src/index.ts"       allow

# notebook_path field (NotebookEdit shape) is honored too.
nb=$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/proj/.env"}}' \
  | bash "$HOOK" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])" 2>/dev/null)
if [[ "$nb" == "deny" ]]; then
  echo "PASS notebook_path .env -> deny ($nb)"; pass=$((pass + 1))
else
  { echo "FAIL notebook_path .env -> deny"; echo "    expected=deny got=$nb"; } >&2; failed=$((failed + 1))
fi

echo ""
echo "test-protect-env.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
