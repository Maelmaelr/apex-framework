#!/usr/bin/env bash
# Purpose: fixtures for the shared content-budget.json contract on the
#          file-health-hook.sh side - per-path word-cap resolution (tier vs
#          default), central-spec exemption, and fail-safe fallback when the
#          budget file is missing. Sibling of test-audit-detectors.sh (which
#          covers the audit-detectors.py side of the same content-budget.json);
#          kept apart from test-apex-scripts.sh (file-health cap) and folded by it.
# Spec: skills/apex/scripts/content-budget.json +
#       skills/apex/scripts/file-health-hook.sh + user-global CLAUDE.md "File health".
#
# Tests run against an ISOLATED fake $HOME tree (its own content-budget.json +
# synthetic docs) so tier resolution is deterministic and independent of the live
# framework files' real sizes. The hook resolves its root via expanduser("~").
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
HOOK="$REPO_ROOT/skills/apex/scripts/file-health-hook.sh"
pass=0
failed=0

check() {  # label expected got
  if [[ "$3" == "$2" ]]; then
    echo "PASS $1 (got=$3)"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected $2, got $3)" >&2; failed=$((failed + 1))
  fi
}

mkdoc() {  # path words -> write a doc of exactly $2 whitespace-joined words
  python3 - "$1" "$2" <<'PY'
import sys
open(sys.argv[1], "w").write(" ".join(["w"] * int(sys.argv[2])))
PY
}

decide() {  # path networds -> run hook under HOME=$FAKE, print permissionDecision
  local ev
  ev=$(python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({"tool_name": "Edit", "tool_input": {
    "file_path": sys.argv[1], "old_string": "",
    "new_string": " ".join(["w"] * int(sys.argv[2]))}}))
PY
)
  printf '%s' "$ev" | HOME="$FAKE" bash "$HOOK" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])'
}

# --- isolated fake tree WITH a content-budget.json (tier skills/apex/SKILL.md=7000) ---
FAKE=$(mktemp -d)
mkdir -p "$FAKE/.claude/skills/apex/scripts" "$FAKE/.claude/skills/apex-improve"
cat > "$FAKE/.claude/skills/apex/scripts/content-budget.json" <<'JSON'
{"default":2500,"central_prose":11400,"tiers":{"skills/apex/SKILL.md":7000},
 "central_prose_members":["apex-core.md","apex-core-overview.md","README.md","CLAUDE.md"],
 "near_cap_ratio":0.85}
JSON

# 1-2. tier file (cap 7000): 6800 + 100 -> allow; 6800 + 300 -> deny.
TIER="$FAKE/.claude/skills/apex/SKILL.md"
mkdoc "$TIER" 6800
check "tier SKILL.md 6900 allow" allow "$(decide "$TIER" 100)"
check "tier SKILL.md 7100 deny" deny "$(decide "$TIER" 300)"

# 3-4. default file (cap 2500, not in tiers): 2400 + 50 -> allow; 2400 + 200 -> deny.
DEF="$FAKE/.claude/skills/apex-improve/apply.md"
mkdoc "$DEF" 2400
check "default apply.md 2450 allow" allow "$(decide "$DEF" 50)"
check "default apply.md 2600 deny" deny "$(decide "$DEF" 200)"

# 5. central spec CLAUDE.md is exempt (never gated) even with a huge growth.
CEN="$FAKE/.claude/CLAUDE.md"
mkdoc "$CEN" 100
check "central CLAUDE.md exempt allow" allow "$(decide "$CEN" 99999)"
rm -rf "$FAKE"

# 6. fail-safe fallback: tree with NO content-budget.json -> hook uses the flat 2500
#    default; a skills .md grown over 2500 denies (graceful, no error).
FAKE=$(mktemp -d)
mkdir -p "$FAKE/.claude/skills/apex"
FB="$FAKE/.claude/skills/apex/foo.md"
mkdoc "$FB" 2400
check "fallback no-budget denies >2500" deny "$(decide "$FB" 200)"
rm -rf "$FAKE"

echo "test-content-budget.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
