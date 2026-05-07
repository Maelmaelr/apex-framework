#!/usr/bin/env bash
# Step 10 (--with-tests): project-aware test runner scoped to modified files.
# Spec: apex-core.md step 10; invoked by verify-build.sh when --with-tests is set.
#
# Auto-detect contract:
#   - If no session baseline at .claude-tmp/apex-active/{session}-baseline.json,
#     skip silently (stderr note); exit 0.
#   - If no test runner declared in the project, skip silently; exit 0.
#   - If modified-files set yields zero derived test files, skip silently; exit 0.
#   - Else run runner on derived set; first-fail-stop semantics, errors written
#     to {session}-verify-errors.txt (same path verify-build.sh uses).
#
# Args:
#   --session <token>     required, 8-char lowercase hex
#   --project-type <t>    required: node | rust | python | go
#   --pm <name>           node only: npm | pnpm | yarn | bun (already resolved by caller)
#
# Exit codes:
#   0  clean (tests passed OR cleanly skipped)
#   1  test command failed (errors file populated)
#   2  invocation error

set -uo pipefail

# Mirror verify-build.sh: anchor APEX_ACTIVE to git-root so we read/write at the
# canonical project-root location regardless of cwd. Required because the
# parent (verify-build.sh) anchors here too; a divergent base would leave the
# errors file orphaned.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
APEX_ACTIVE="$PROJECT_ROOT/.claude-tmp/apex-active"
SESSION=""
PROJECT_TYPE=""
PM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)      SESSION="${2:-}"; shift 2 ;;
    --project-type) PROJECT_TYPE="${2:-}"; shift 2 ;;
    --pm)           PM="${2:-}"; shift 2 ;;
    *) echo "verify-tests.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SESSION" ]] || { echo "verify-tests.sh: --session is required" >&2; exit 2; }
[[ "$SESSION" =~ ^[0-9a-f]{8}$ ]] || { echo "verify-tests.sh: bad session shape: $SESSION" >&2; exit 2; }
[[ -n "$PROJECT_TYPE" ]] || { echo "verify-tests.sh: --project-type is required" >&2; exit 2; }

ERRORS_FILE="$APEX_ACTIVE/${SESSION}-verify-errors.txt"
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# Modified-files set. Empty stdout AND non-zero exit means "no baseline; skip".
get_modified_files() {
  local baseline="$APEX_ACTIVE/${SESSION}-baseline.json"
  [[ -f "$baseline" ]] || return 1
  local head_sha
  head_sha=$(python3 -c "import json; print(json.load(open('$baseline')).get('head_sha',''))" 2>/dev/null) || return 1
  [[ -n "$head_sha" ]] || return 1
  { git diff --name-only "$head_sha" -- . 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
}

run_or_fail() {
  local label="$1" cmd="$2"
  : > "$TMP_OUT"
  local rc=0
  bash -c "$cmd" >"$TMP_OUT" 2>&1 || rc=$?
  if (( rc != 0 )); then
    {
      printf '## verify-tests.sh: %s FAILED (exit %d)\n' "$label" "$rc"
      printf '## command: %s\n' "$cmd"
      printf '## cwd: %s\n' "$(pwd)"
      printf '## ----- output -----\n'
      cat "$TMP_OUT"
    } > "$ERRORS_FILE"
    echo "verify-tests.sh: $label FAILED (exit $rc); errors -> $ERRORS_FILE" >&2
    exit 1
  fi
}

has_bin() { command -v "$1" >/dev/null 2>&1; }

skip() {
  echo "verify-tests.sh: $1; skipping tests phase" >&2
  exit 0
}

MODIFIED=$(get_modified_files) || skip "no session baseline"
[[ -n "$MODIFIED" ]] || skip "no modified files"

case "$PROJECT_TYPE" in

  node)
    [[ -f package.json ]] || skip "no package.json"
    if [[ -z "$PM" ]]; then
      if   [[ -f bun.lock || -f bun.lockb ]]; then PM="bun"
      elif [[ -f pnpm-lock.yaml           ]]; then PM="pnpm"
      elif [[ -f yarn.lock                ]]; then PM="yarn"
      else                                         PM="npm"
      fi
      has_bin "$PM" || PM="npm"
    fi
    NPM_SCRIPTS=" $(python3 -c "
import json
try: d = json.load(open('package.json'))
except Exception: raise SystemExit
print(' '.join((d.get('scripts') or {}).keys()))
") "
    [[ "$NPM_SCRIPTS" == *" test "* ]] || skip "no 'test' script in package.json"
    RUNNER=$(python3 -c "
import json
try: d = json.load(open('package.json'))
except Exception: raise SystemExit
deps = {**(d.get('dependencies') or {}), **(d.get('devDependencies') or {})}
if 'vitest' in deps: print('vitest')
elif 'jest' in deps: print('jest')
else: print('')
")
    case "$PM" in
      npm)  RUN_PREFIX="npm run --silent" ;;
      pnpm) RUN_PREFIX="pnpm run" ;;
      yarn) RUN_PREFIX="yarn run" ;;
      bun)  RUN_PREFIX="bun run" ;;
      *)    RUN_PREFIX="npm run --silent" ;;
    esac
    NODE_FILES=$(printf '%s\n' "$MODIFIED" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' || true)
    [[ -n "$NODE_FILES" ]] || skip "no JS/TS files in modified set"
    # Filter to files that still exist (deletions excluded).
    EXISTING=$(printf '%s\n' "$NODE_FILES" | while IFS= read -r f; do [[ -f "$f" ]] && echo "$f"; done)
    [[ -n "$EXISTING" ]] || skip "no existing JS/TS files in modified set"
    if [[ "$RUNNER" == "vitest" ]]; then
      run_or_fail "vitest related" "$RUN_PREFIX test -- --run --related $(echo "$EXISTING" | tr '\n' ' ')"
    elif [[ "$RUNNER" == "jest" ]]; then
      run_or_fail "jest --findRelatedTests" "$RUN_PREFIX test -- --findRelatedTests $(echo "$EXISTING" | tr '\n' ' ')"
    else
      # Heuristic: pick test files matching modified non-test files; include test files in modified set.
      DERIVED=$(python3 - "$EXISTING" <<'PY'
import os, sys
files = [ln for ln in sys.argv[1].splitlines() if ln.strip()]
out = set()
test_re_suffixes = ('.test.ts','.test.tsx','.test.js','.test.jsx','.spec.ts','.spec.tsx','.spec.js','.spec.jsx')
for f in files:
    if f.endswith(test_re_suffixes) or '/__tests__/' in f:
        if os.path.isfile(f): out.add(f)
        continue
    d = os.path.dirname(f) or '.'
    base = os.path.basename(f); stem,_,_ = base.rpartition('.')
    if not stem: continue
    cands = []
    for ext in ('.ts','.tsx','.js','.jsx'):
        cands.append(f"{d}/{stem}.test{ext}")
        cands.append(f"{d}/{stem}.spec{ext}")
        cands.append(f"{d}/__tests__/{stem}.test{ext}")
        cands.append(f"{d}/__tests__/{stem}{ext}")
    for c in cands:
        if os.path.isfile(c): out.add(c)
print('\n'.join(sorted(out)))
PY
)
      [[ -n "$DERIVED" ]] || skip "no related test files (heuristic)"
      run_or_fail "test (heuristic)" "$RUN_PREFIX test -- $(echo "$DERIVED" | tr '\n' ' ')"
    fi
    ;;

  rust)
    has_bin cargo || skip "cargo not on PATH"
    RS_FILES=$(printf '%s\n' "$MODIFIED" | grep -E '\.rs$' || true)
    [[ -n "$RS_FILES" ]] || skip "no .rs files in modified set"
    # Map each .rs file to nearest Cargo.toml dir; take basename of that dir
    # only when the workspace is multi-package (root Cargo.toml has [workspace]).
    PKGS=$(python3 - "$RS_FILES" <<'PY'
import os, sys
files = [ln for ln in sys.argv[1].splitlines() if ln.strip()]
def find_cargo(p):
    d = os.path.dirname(os.path.abspath(p))
    while d and d != '/':
        c = os.path.join(d, 'Cargo.toml')
        if os.path.isfile(c): return c
        d = os.path.dirname(d)
    return ''
def pkg_name(toml):
    try: text = open(toml).read()
    except: return ''
    import re
    m = re.search(r'(?m)^\s*\[package\]\s*\n(?:.*\n)*?\s*name\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else ''
seen = set()
for f in files:
    if not os.path.isfile(f): continue
    c = find_cargo(f)
    if not c: continue
    n = pkg_name(c)
    if n: seen.add(n)
print('\n'.join(sorted(seen)))
PY
)
    [[ -n "$PKGS" ]] || skip "no cargo packages resolved"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      run_or_fail "cargo test -p $p" "cargo test --quiet --no-fail-fast -p $p"
    done <<< "$PKGS"
    ;;

  python)
    has_bin pytest || skip "pytest not on PATH"
    PY_FILES=$(printf '%s\n' "$MODIFIED" | grep -E '\.py$' || true)
    [[ -n "$PY_FILES" ]] || skip "no .py files in modified set"
    DERIVED=$(python3 - "$PY_FILES" <<'PY'
import os, sys
files = [ln for ln in sys.argv[1].splitlines() if ln.strip()]
out = set()
for f in files:
    if not os.path.isfile(f): continue
    base = os.path.basename(f)
    if base.startswith('test_') or base.endswith('_test.py') or '/tests/' in f or f.startswith('tests/'):
        out.add(f); continue
    stem = base[:-3] if base.endswith('.py') else base
    d = os.path.dirname(f) or '.'
    for c in (f"tests/test_{stem}.py", f"tests/{d}/test_{stem}.py", f"{d}/test_{stem}.py", f"{d}/tests/test_{stem}.py"):
        if os.path.isfile(c): out.add(c)
print('\n'.join(sorted(out)))
PY
)
    [[ -n "$DERIVED" ]] || skip "no related pytest files"
    run_or_fail "pytest (related)" "pytest -x --no-header $(echo "$DERIVED" | tr '\n' ' ')"
    ;;

  go)
    has_bin go || skip "go not on PATH"
    GO_FILES=$(printf '%s\n' "$MODIFIED" | grep -E '\.go$' || true)
    [[ -n "$GO_FILES" ]] || skip "no .go files in modified set"
    DIRS=$(printf '%s\n' "$GO_FILES" | while IFS= read -r f; do
      [[ -f "$f" ]] && dirname "$f"
    done | sort -u)
    [[ -n "$DIRS" ]] || skip "no existing .go file dirs"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      run_or_fail "go test ./$d" "go test ./$d/..."
    done <<< "$DIRS"
    ;;

  *) echo "verify-tests.sh: unknown project type: $PROJECT_TYPE" >&2; exit 2 ;;
esac

echo "verify-tests.sh: clean" >&2
exit 0
