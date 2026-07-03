#!/usr/bin/env bash
# Deterministic validation gate for the apex framework (~/.claude).
# Run by /admin-apex before committing; safe to run any time, read-only.
#
# Checks (apex family only - other skills under skills/ are third-party):
#   1. bash -n on every apex shell script
#   2. py_compile on every apex python script
#   3. JSON parse: settings.json + content-budget.json
#   4. Hook smoke: the four PreToolUse hooks must return "allow" on benign input
#   5. Word budgets: apex-family .md files within content-budget.json caps
#
# Exit 0 all green; exit 1 with one "validate FAIL: ..." stderr line per failure.
set -uo pipefail

ROOT="${APEX_PRIVATE:-$HOME/.claude}"
APEX_DIRS=("$ROOT/skills/apex" "$ROOT/skills/apex-merge" "$ROOT/skills/apex-init" \
           "$ROOT/skills/apex-git" "$ROOT/skills/admin-apex" "$ROOT/agents")
fail=0
err() { echo "validate FAIL: $*" >&2; fail=1; }

# 1+2: syntax
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || err "bash -n $f"
done < <(find "${APEX_DIRS[@]}" -name '*.sh' -not -path '*__pycache__*' 2>/dev/null)
while IFS= read -r f; do
  python3 -m py_compile "$f" 2>/dev/null || err "py_compile $f"
done < <(find "${APEX_DIRS[@]}" -name '*.py' -not -path '*__pycache__*' 2>/dev/null)

# 3: JSON
for j in "$ROOT/settings.json" "$ROOT/skills/apex/scripts/content-budget.json"; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$j" 2>/dev/null || err "json parse $j"
done

# 4: hook smoke (benign inputs -> allow)
EDIT_IN='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/skills/apex/SKILL.md"'
EDIT_IN+=',"old_string":"a","new_string":"b"}}'
BASH_IN='{"tool_name":"Bash","tool_input":{"command":"echo ok"}}'
for h in worktree-fence-hook file-health-hook protect-env-hook; do
  out=$(printf '%s' "$EDIT_IN" | bash "$ROOT/skills/apex/scripts/$h.sh" 2>/dev/null)
  [[ "$out" == *'"allow"'* ]] || err "$h.sh did not allow benign edit"
done
out=$(printf '%s' "$BASH_IN" | bash "$ROOT/skills/apex/scripts/block-destructive-hook.sh" 2>/dev/null)
[[ "$out" == *'"allow"'* ]] || err "block-destructive-hook.sh did not allow benign bash"

# 5: word budgets (apex-family .md only)
python3 - "$ROOT" <<'PY' || fail=1
import json, os, sys
root = sys.argv[1]
budget_path = os.path.join(root, "skills/apex/scripts/content-budget.json")
budget = json.load(open(budget_path, encoding="utf-8"))
default, tiers = budget.get("default", 2500), budget.get("tiers", {})
bases = ["skills/apex", "skills/apex-merge", "skills/apex-init",
         "skills/apex-git", "skills/admin-apex", "agents"]
bad = []
for base in bases:
    top = os.path.join(root, base)
    if not os.path.isdir(top):
        continue
    for dirpath, _, names in os.walk(top):
        for n in names:
            if not n.endswith(".md"):
                continue
            p = os.path.join(dirpath, n)
            rel = os.path.relpath(p, root)
            words = len(open(p, encoding="utf-8", errors="replace").read().split())
            cap = tiers.get(rel, default)
            if words > cap:
                bad.append(f"word budget {rel}: {words} > {cap}")
for b in bad:
    print("validate FAIL: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

if [[ $fail -eq 0 ]]; then
  echo "validate: all checks passed"
fi
exit $fail
