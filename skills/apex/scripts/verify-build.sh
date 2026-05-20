#!/usr/bin/env bash
# Step 10: project-aware lint + build verifier.
# Spec: apex-core.md step 10.
#
# Detects project type by manifest (priority order):
#   package.json    -> node (pnpm | yarn | bun | npm by lockfile)
#   Cargo.toml      -> rust  (cargo check + cargo clippy if available)
#   pyproject.toml  -> python (ruff + mypy if available)
#   go.mod          -> go    (go vet + go build)
# No manifest -> exit 0 with stderr note ("nothing to verify").
#
# Runs the available lint / typecheck / build commands sequentially. First
# non-zero command wins: combined stdout+stderr is written to
#   .claude-tmp/apex-active/{session}-verify-errors.txt
# and the script exits with that command's status. Subsequent commands are
# skipped (cascading errors from a broken typecheck/build typically confuse
# the fix-attempt executor; first-fail keeps the executor's input focused).
#
# Lint phases auto-apply machine-fixable suggestions before reporting:
#   node:   best-effort `--fix` pre-pass against the project's `lint` script
#           (eslint/biome wrappers; harmless no-op when the underlying tool
#            doesn't accept --fix, e.g. tsc-as-lint).
#   ruff:   `ruff check --fix .` (single pass; ruff fixes in-place and reports
#            remaining issues).
#   clippy: `cargo clippy --fix --allow-dirty --allow-staged ... -- -D warnings`
#            (--allow-dirty needed because the executor has just edited files).
# Auto-fix files are mutated in place; this is intentional and out of scope
# for the apex scope-check hook (verify-build.sh is invoked outside the
# executor's tool-call gate).
#
# Args:
#   --session <token>   required, 8-char lowercase hex
#   --with-tests        optional, opt-in test phase after build (delegates to
#                       verify-tests.sh; project-aware; tests scoped to files
#                       modified since session baseline; auto-skip when no
#                       baseline / no test runner / no related tests)
#   --in-scope-only     optional. When set, a first-fail whose error output
#                       implicates NO file in {session}-main-scope.json
#                       allowed_files is treated as foreign / pre-existing
#                       debt and the script exits 0 (errors file removed).
#                       Defends step 10 against sibling baseline-dirty lint
#                       failures that would otherwise abort the in-scope
#                       verify on first-fail-stop. Recurring 2-session
#                       request: 6689bc2b (xai_image_helpers complexity 24),
#                       51b2f54a (canvas_stitch_worker_client cogcomplexity
#                       17). No main-scope.json / no jq -> falls back to the
#                       normal (no-flag) behavior so the flag is safe to pass
#                       universally.
#
# Exit codes:
#   0  clean (all available commands passed) OR no recognized manifest
#      OR (--in-scope-only) only foreign / pre-existing debt failed
#   1  one of the verify commands failed (errors file populated; with
#      --in-scope-only, only when at least one in-scope file is implicated)
#   2  invocation error (bad args, malformed session token)

set -uo pipefail

# Anchor APEX_ACTIVE to git-root so verify-build.sh writes the errors file at
# the canonical project-root location regardless of cwd. Falls back to pwd when
# not inside a git repo (rare; manifest detection below would also fail).
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
APEX_ACTIVE="$PROJECT_ROOT/.claude-tmp/apex-active"
SESSION=""
WITH_TESTS=0
IN_SCOPE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --with-tests)
      WITH_TESTS=1
      shift
      ;;
    --in-scope-only)
      IN_SCOPE_ONLY=1
      shift
      ;;
    *)
      echo "verify-build.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SESSION" ]]; then
  echo "verify-build.sh: --session is required" >&2
  exit 2
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "verify-build.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 2
fi

mkdir -p "$APEX_ACTIVE"
ERRORS_FILE="$APEX_ACTIVE/${SESSION}-verify-errors.txt"
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# Reset prior errors file (consumer treats absence as clean).
rm -f "$ERRORS_FILE"

# Run a single verify command. On non-zero exit, write the full transcript
# (label + command + combined output) to ERRORS_FILE and exit with that status.
# On zero, return silently so the caller continues to the next command.
#
# Optional 3rd arg `warn_as_error` (0|1, default 0): when 1 and the command
# exited 0, scan combined output for lint-warning lines and treat any match
# as a failure. Used by lint phases so warnings flow through the same fix-loop
# as errors (clippy already has -D warnings; this closes the gap for node lint
# scripts that don't pass --max-warnings=0, biome's default warning severity,
# etc).
#
# Warning detector: matches eslint stylekit `<file>:<line>:<col>  warning  ...`,
# biome `warning[...]:`, golangci `warning:`, generic ` warn:` / ` warning:`
# prefixes. Build/typecheck phases pass warn_as_error=0 (build warnings are
# noisy and not the linter's domain).
run_or_fail() {
  local label="$1"
  local cmd="$2"
  local warn_as_error="${3:-0}"
  local scope_annotate="${4:-0}"
  : > "$TMP_OUT"
  local rc=0
  bash -c "$cmd" >"$TMP_OUT" 2>&1 || rc=$?
  if (( rc == 0 && warn_as_error == 1 )); then
    if grep -qE '(^|[[:space:]])(warning|warn)(s)?([[:space:]]|:|\[)' "$TMP_OUT"; then
      rc=1
      {
        printf '## verify-build.sh: %s FAILED (lint warnings; warn-as-error)\n' "$label"
        printf '## command: %s\n' "$cmd"
        printf '## cwd: %s\n' "$(pwd)"
        printf '## ----- output -----\n'
        cat "$TMP_OUT"
      } > "$ERRORS_FILE"
      echo "verify-build.sh: $label FAILED (lint warnings; warn-as-error); errors -> $ERRORS_FILE" >&2
      if (( scope_annotate == 1 )); then
        if ! annotate_foreign_lint && (( IN_SCOPE_ONLY == 1 )); then
          echo "verify-build.sh: $label foreign-only (no in-scope file implicated); --in-scope-only treats as clean" >&2
          rm -f "$ERRORS_FILE"
          exit 0
        fi
      fi
      exit 1
    fi
  fi
  if (( rc != 0 )); then
    {
      printf '## verify-build.sh: %s FAILED (exit %d)\n' "$label" "$rc"
      printf '## command: %s\n' "$cmd"
      printf '## cwd: %s\n' "$(pwd)"
      printf '## ----- output -----\n'
      cat "$TMP_OUT"
    } > "$ERRORS_FILE"
    echo "verify-build.sh: $label FAILED (exit $rc); errors -> $ERRORS_FILE" >&2
    (( scope_annotate == 1 )) && annotate_foreign_lint
    exit 1
  fi
}

# F2 (reflector cluster 0c22bd50 / 8309ce2e / 9401d64d / 00b95640): a lint
# failure that implicates NO in-scope allowed_file is foreign / pre-existing
# debt in an unmodified package, not what this session's executor produced.
# We still first-fail-stop (never fail open - silently masking a real
# in-scope regression is worse than a noisy foreign one), but append a
# greppable NOTE so the step-10 orchestrator runs the scoped in-scope
# lint/tsc/build the reflectors had to derive by hand (see apex-core.md
# step 10). No main-scope.json / no jq -> no-op (behavior unchanged).
# Returns 0 if at least one in-scope allowed_file is implicated in the error
# output, 1 if the failure is entirely foreign (used by --in-scope-only).
annotate_foreign_lint() {
  local scope_json="$APEX_ACTIVE/${SESSION}-main-scope.json"
  command -v jq >/dev/null 2>&1 && [[ -f "$scope_json" ]] || return 0
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && grep -Fq -- "$f" "$TMP_OUT" && return 0
  done < <(jq -r '.allowed_files[]?' "$scope_json" 2>/dev/null || true)
  printf '## NOTE: no in-scope allowed_file implicated - lint failure appears foreign/pre-existing; orchestrator should verify in-scope lint/typecheck/build separately before treating the run as blocked (apex-core.md step 10).\n' >> "$ERRORS_FILE"
  return 1
}

# Cached space-padded list of npm script names; populated once per run when
# PROJECT_TYPE=node. Membership check is a portable bash substring test.
NPM_SCRIPTS=""

load_npm_scripts() {
  NPM_SCRIPTS=" $(python3 -c "
import json, sys
try:
    with open('package.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
print(' '.join((data.get('scripts') or {}).keys()))
") "
}

has_npm_script() {
  [[ "$NPM_SCRIPTS" == *" $1 "* ]]
}

# Returns 0 if the binary is on PATH.
has_bin() { command -v "$1" >/dev/null 2>&1; }

# --- Detect project type (first manifest wins) ---

PROJECT_TYPE=""
if [[ -f package.json ]]; then
  PROJECT_TYPE="node"
elif [[ -f Cargo.toml ]]; then
  PROJECT_TYPE="rust"
elif [[ -f pyproject.toml ]]; then
  PROJECT_TYPE="python"
elif [[ -f go.mod ]]; then
  PROJECT_TYPE="go"
else
  echo "verify-build.sh: no recognized manifest at $(pwd); nothing to verify" >&2
  exit 0
fi

echo "verify-build.sh: project type = $PROJECT_TYPE; session = $SESSION" >&2

# --- Dispatch ---

case "$PROJECT_TYPE" in

  node)
    # Pick package manager by lockfile (closed set; falls through to npm).
    if   [[ -f bun.lock || -f bun.lockb ]]; then PM="bun"
    elif [[ -f pnpm-lock.yaml           ]]; then PM="pnpm"
    elif [[ -f yarn.lock                ]]; then PM="yarn"
    else                                         PM="npm"
    fi
    if ! has_bin "$PM"; then
      echo "verify-build.sh: package manager '$PM' not on PATH; falling back to npm" >&2
      PM="npm"
    fi

    # Build the run-prefix. `npm run --silent` suppresses the "> pkg@ver build" header
    # (a noise source the fixer doesn't need); pnpm/yarn/bun emit cleaner output by default.
    case "$PM" in
      npm)  RUN_PREFIX="npm run --silent" ;;
      pnpm) RUN_PREFIX="pnpm run" ;;
      yarn) RUN_PREFIX="yarn run" ;;
      bun)  RUN_PREFIX="bun run" ;;
    esac

    # npm needs `--` to forward args; pnpm/yarn/bun pass them directly.
    [[ "$PM" == "npm" ]] && LINT_FIX_ARGS="-- --fix" || LINT_FIX_ARGS="--fix"

    load_npm_scripts
    ran_anything=0
    # Order matters: lint -> typecheck -> build.
    # A typecheck failure usually cascades into build, so first-fail-stop keeps
    # the fix executor focused on the upstream cause.
    # Lint phase: best-effort `--fix` pre-pass auto-resolves machine-fixable
    # issues (eslint/biome wrappers) before the canonical lint runs - cuts
    # fix-loop tokens for trivial issues. Failure is harmless (e.g., a tsc-as-
    # lint script that doesn't accept --fix); output suppressed so only the
    # canonical pass surfaces to the executor. Then warn_as_error=1 so
    # eslint/biome warnings feed the same fix-loop as errors (closes the gap
    # for projects whose `lint` script doesn't pass --max-warnings=0).
    for script in lint typecheck build; do
      if has_npm_script "$script"; then
        ran_anything=1
        if [[ "$script" == "lint" ]]; then
          bash -c "$RUN_PREFIX lint $LINT_FIX_ARGS" >/dev/null 2>&1 || true
          run_or_fail "lint ($PM)" "$RUN_PREFIX lint" 1 1
        else
          run_or_fail "$script ($PM)" "$RUN_PREFIX $script" 0
        fi
      fi
    done
    if (( ran_anything == 0 )); then
      echo "verify-build.sh: no lint/typecheck/build scripts in package.json; nothing to verify" >&2
    fi
    ;;

  rust)
    if ! has_bin cargo; then
      echo "verify-build.sh: cargo not on PATH; cannot verify Rust project" >&2
      exit 0
    fi
    # `cargo check` is the fast type/borrow verifier (skips codegen). Clippy is the
    # canonical lint; only run it when actually installed (rustup component add clippy).
    # `--fix --allow-dirty --allow-staged` auto-applies machine-fixable suggestions
    # before -D warnings gates the rest (cuts fix-loop tokens; --allow-dirty needed
    # because the executor has just edited files in this session).
    if cargo clippy --version >/dev/null 2>&1; then
      run_or_fail "cargo clippy" "cargo clippy --fix --allow-dirty --allow-staged --quiet --all-targets -- -D warnings"
    fi
    run_or_fail "cargo check" "cargo check --quiet --all-targets"
    ;;

  python)
    ran_anything=0
    # ruff `--fix` auto-applies machine-fixable lints in-place; remaining
    # (unsafe-fix / non-fixable) issues still surface to the fix-loop.
    if has_bin ruff; then
      ran_anything=1
      run_or_fail "ruff check" "ruff check --fix ." 1
    fi
    if has_bin mypy; then
      ran_anything=1
      run_or_fail "mypy" "mypy ."
    fi
    if (( ran_anything == 0 )); then
      echo "verify-build.sh: neither ruff nor mypy on PATH; nothing to verify (Python)" >&2
    fi
    ;;

  go)
    if ! has_bin go; then
      echo "verify-build.sh: go not on PATH; cannot verify Go project" >&2
      exit 0
    fi
    run_or_fail "go vet"   "go vet ./..." 1
    run_or_fail "go build" "go build ./..."
    ;;
esac

if (( WITH_TESTS == 1 )); then
  TEST_ARGS=(--session "$SESSION" --project-type "$PROJECT_TYPE")
  [[ "$PROJECT_TYPE" == "node" && -n "${PM:-}" ]] && TEST_ARGS+=(--pm "$PM")
  bash "$(dirname "$0")/verify-tests.sh" "${TEST_ARGS[@]}" || exit 1
fi

echo "verify-build.sh: clean" >&2
exit 0
