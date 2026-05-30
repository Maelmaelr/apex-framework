#!/usr/bin/env bash
# Purpose: fixtures for scripts/audit-detectors.py (the shared detector engine
#          A1 extracted from polish-check.sh + audit.md).
# Spec: skills/admin-apex/audit.md task 3 + scripts/polish-check.sh.
#
# Kept separate from test-apex-scripts.sh (which is already near the 400-line
# file-health cap) - that harness invokes this one and folds the result.
# Also runnable standalone.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
ENG="$REPO_ROOT/skills/admin-apex/scripts/audit-detectors.py"
pass=0
failed=0

check() {  # label expected-exit got-exit
  if [[ "$3" == "$2" ]]; then
    echo "PASS $1 (exit=$3)"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected $2, got $3)" >&2; failed=$((failed + 1))
  fi
}

# Synthetic inventory exercising the structural detectors without disk reads
# (oversized = doc word-budget compare; schema-mismatch = pure id-vs-basename).
INV_DRIFT='{"skills":[{"path":"skills/apex/big.md","lines":222,"words":3000}],"agents":[],"scripts":[],"schemas":[{"path":"skills/apex/schemas/x.schema.json","id":"WRONG.json"}],"hooks":[],"spec_docs":[],"version":"0"}'
INV_SCHEMA='{"skills":[],"agents":[],"scripts":[],"schemas":[{"path":"skills/apex/schemas/x.schema.json","id":"WRONG.json"}],"hooks":[],"spec_docs":[],"version":"0"}'

# 1. Missing --mode -> argparse usage error, exit 2.
python3 "$ENG" --inventory /tmp/x --run abcd1234 >/dev/null 2>&1
check "missing-mode exit2" 2 $?

# 2. audit mode: oversized + schema-mismatch detected; --extra-clusters appended LAST.
inv=$(mktemp); extra=$(mktemp)
printf '%s' "$INV_DRIFT" > "$inv"
printf '%s' '[{"id":"user-driven","kind":"user-driven","items":["skills/apex/foo.md"],"summary":"c"}]' > "$extra"
out=$(python3 "$ENG" --inventory "$inv" --mode audit --run abcd1234 --extra-clusters "$extra" 2>/dev/null)
AD_OUT="$out" python3 -c '
import json, os, sys
k = [c["kind"] for c in json.loads(os.environ["AD_OUT"])["clusters"]]
sys.exit(0 if ("oversized-files" in k and "schema-mismatch" in k and k and k[-1] == "user-driven") else 1)
'
check "audit detect+merge" 0 $?
rm -f "$inv" "$extra"

# 3. polish mode: schema mismatch, empty prior -> NEW drift -> exit 1.
inv=$(mktemp); prior=$(mktemp); out=$(mktemp)
printf '%s' "$INV_SCHEMA" > "$inv"
printf '%s' '{"run":"x","clusters":[]}' > "$prior"
python3 "$ENG" --inventory "$inv" --mode polish --run abcd1234 --prior-drift "$prior" --out "$out" >/dev/null 2>&1
check "polish new-drift exit1" 1 $?
rm -f "$inv" "$prior" "$out"

# 4. polish mode: every detected item already in prior drift -> diff suppresses -> exit 0.
#    The lone unreferenced schema entry trips BOTH schema-mismatch and missing-refs,
#    so the prior must carry both ids for the NEW-only diff to net empty.
inv=$(mktemp); prior=$(mktemp); out=$(mktemp)
printf '%s' "$INV_SCHEMA" > "$inv"
printf '%s' '{"run":"x","clusters":[{"id":"schema","kind":"inconsistency","items":["skills/apex/schemas/x.schema.json (id=WRONG.json)"]},{"id":"missing","kind":"unused","items":["skills/apex/schemas/x.schema.json"]}]}' > "$prior"
python3 "$ENG" --inventory "$inv" --mode polish --run abcd1234 --prior-drift "$prior" --out "$out" >/dev/null 2>&1
check "polish no-new-drift exit0" 0 $?
rm -f "$inv" "$prior" "$out"

echo "test-audit-detectors.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
