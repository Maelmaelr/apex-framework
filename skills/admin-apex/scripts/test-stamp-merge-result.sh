#!/usr/bin/env bash
# Purpose: fixtures for skills/apex-merge/scripts/stamp-merge-result.sh (plan F22).
#          Asserts the orchestrator's terminal-stamp populates merge-result.json so
#          BOTH step-4.6 touchpoints (RESOLVED_CONFLICTS count + conflict-touched
#          paths filter) fire after a real conflict resolution - the bug F22 fixes.
# Spec: apex-context-rot-optimization plan "READY-NOW F22"; skills/apex-merge/SKILL.md
#       step 4 + step 4.6; skills/apex-merge/resolve-one-conflict.md.
#
# Kept separate from test-apex-scripts.sh (near the 400-line file-health cap),
# which invokes this one and folds the result. Also runnable standalone.
#
# Each case seeds a transient `conflict` entry (the shape merge-loop.sh writes on
# exit 20), runs stamp-merge-result.sh, and asserts the resulting entry + the two
# downstream step-4.6 operations (replicated in python so the test carries no jq
# dependency; mirrors SKILL.md 4.6's jq pipeline exactly).
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
STAMP="$REPO_ROOT/skills/apex-merge/scripts/stamp-merge-result.sh"
TOKEN="abcd1234"
pass=0
failed=0

ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { { echo "FAIL $1"; shift; printf '    %s\n' "$@"; } >&2; failed=$((failed + 1)); }

# Seed a result file with one transient conflict entry under a sandbox HOME.
seed() {  # thome detail
  local thome="$1" detail="$2"
  mkdir -p "$thome/.claude/.claude-tmp/apex-merge-active"
  printf '[{"branch":"apex/%s","base":"main","status":"conflict","detail":"%s"}]\n' \
    "$TOKEN" "$detail" > "$thome/.claude/.claude-tmp/apex-merge-active/$TOKEN-merge-result.json"
}

# Run stamp-merge-result.sh under a sandbox HOME, silencing output.
stamp() {  # thome <stamp args...>
  local thome="$1"; shift
  HOME="$thome" bash "$STAMP" "$TOKEN" "$@" >/dev/null 2>&1
}

# Read field [0].<key> from a result file ('' if absent / parse error).
field() {  # result-file key
  python3 -c "import json;d=json.load(open('$1'))[0];print(d.get('$2',''))" 2>/dev/null
}

# Replicate step-4.6's RESOLVED_CONFLICTS count + lintable-path filter in python.
# Prints "<count>\t<comma-joined lintable paths>".
downstream() {  # result-file
  python3 - "$1" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
count = sum(1 for e in data if e.get("status") == "merged" and "resolver=" in (e.get("detail") or ""))
lint = []
for e in data:
    if e.get("status") != "merged" or not re.search("resolver=", e.get("detail") or ""):
        continue
    for p in (e.get("paths") or ([e["path"]] if e.get("path") else [])):
        if re.search(r"\.(ts|tsx|js|jsx|mjs|cjs|json)$", p):
            lint.append(p)
print("%d\t%s" % (count, ",".join(lint)))
PY
}

R="/.claude/.claude-tmp/apex-merge-active/$TOKEN-merge-result.json"

# --- case 1: merged + accept + lintable paths -> both touchpoints fire ---
T=$(mktemp -d); seed "$T" "src/a.ts,src/b.tsx"
stamp "$T" --branch "apex/$TOKEN" --status merged --decision accept --paths "src/a.ts,src/b.tsx"; rc=$?
read -r cnt paths < <(downstream "$T$R")
if [[ "$rc" == 0 && "$(field "$T$R" status)" == "merged" \
      && "$(field "$T$R" detail)" == "resolver=accept" \
      && "$cnt" == 1 && "$paths" == "src/a.ts,src/b.tsx" ]]; then
  ok "merged stamp -> resolver= + paths, 4.6 count=1 + lintable paths"
else
  bad "merged stamp" "rc=$rc count=$cnt paths=$paths"
fi
rm -rf "$T"

# --- case 2: abort -> skipped-conflict-abort, no resolver stamp, 4.6 count=0 ---
T=$(mktemp -d); seed "$T" "src/a.ts"
stamp "$T" --branch "apex/$TOKEN" --status skipped-conflict-abort; rc=$?
read -r cnt _ < <(downstream "$T$R")
has_paths=$(python3 -c "import json;print('paths' in json.load(open('$T$R'))[0])" 2>/dev/null)
if [[ "$rc" == 0 && "$(field "$T$R" status)" == "skipped-conflict-abort" \
      && "$cnt" == 0 && "$has_paths" == "False" ]]; then
  ok "abort stamp -> skipped-conflict-abort, 4.6 count=0 (no apex-fix)"
else
  bad "abort stamp" "rc=$rc count=$cnt has_paths=$has_paths"
fi
rm -rf "$T"

# --- case 3: markdown-only resolved paths -> count=1 but lintable filter empty ---
T=$(mktemp -d); seed "$T" "docs/x.md"
stamp "$T" --branch "apex/$TOKEN" --status merged --decision accept --paths "docs/x.md,notes.md"; rc=$?
read -r cnt paths < <(downstream "$T$R")
if [[ "$rc" == 0 && "$cnt" == 1 && -z "$paths" ]]; then
  ok "markdown-only stamp -> count=1, lintable filter empty (4.6 skips apex-fix)"
else
  bad "markdown-only stamp" "rc=$rc count=$cnt paths=$paths"
fi
rm -rf "$T"

# --- case 4: idempotent re-stamp -> single entry, paths updated in place ---
T=$(mktemp -d); seed "$T" "src/a.ts"
stamp "$T" --branch "apex/$TOKEN" --status merged --decision accept --paths "src/a.ts"
stamp "$T" --branch "apex/$TOKEN" --status merged --decision reject-edit-manually --paths "src/a.ts,src/c.ts"; rc=$?
n=$(python3 -c "import json;print(len(json.load(open('$T$R'))))" 2>/dev/null)
npaths=$(python3 -c "import json;print(len(json.load(open('$T$R'))[0]['paths']))" 2>/dev/null)
if [[ "$rc" == 0 && "$n" == 1 && "$(field "$T$R" detail)" == "resolver=reject-edit-manually" \
      && "$npaths" == 2 ]]; then
  ok "idempotent re-stamp -> single entry, detail+paths updated"
else
  bad "idempotent re-stamp" "rc=$rc entries=$n npaths=$npaths"
fi
rm -rf "$T"

# --- case 5: unknown branch -> exit 1 ---
T=$(mktemp -d); seed "$T" "src/a.ts"
stamp "$T" --branch "apex/deadbeef" --status merged --decision accept --paths "src/a.ts"; rc=$?
[[ "$rc" == 1 ]] && ok "unknown branch -> exit 1" || bad "unknown branch" "expected exit 1, got $rc"
rm -rf "$T"

# --- case 6: merged without --decision -> exit 1 (arg validation) ---
T=$(mktemp -d); seed "$T" "src/a.ts"
stamp "$T" --branch "apex/$TOKEN" --status merged --paths "src/a.ts"; rc=$?
[[ "$rc" == 1 ]] && ok "merged without --decision -> exit 1" || bad "missing decision" "expected exit 1, got $rc"
rm -rf "$T"

echo ""
echo "test-stamp-merge-result.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
