#!/usr/bin/env bash
# Project-aware lint + build verifier (the /apex verify gate).
# Verify gate: whole-repo typecheck/build (+ optional tests) for /apex.
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
#   node:   scope-isolated `eslint --fix` over ONLY the session's allowed_files
#           (see scoped_lint_fix); never a repo-wide --fix that would reformat
#           out-of-scope files into the commit.
#   ruff:   `ruff check --fix .` (single pass; fixes in-place, reports the rest).
#   clippy: `cargo clippy --fix --allow-dirty --allow-staged ... -- -D warnings`
#            (--allow-dirty needed because the executor has just edited files).
# Auto-fix files are mutated in place; intentional (verify-build.sh runs
# outside the editor tool hooks).
# Python tooling (ruff/mypy/pytest) resolves via the project venv when present:
# a local .venv/venv/env bin dir is prepended to PATH before dispatch.
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
#                       Defends the verify gate against sibling baseline-dirty lint
#                       failures that would otherwise abort the in-scope verify
#                       on first-fail-stop. No main-scope.json / no jq -> falls
#                       back to normal (no-flag) behavior, so it is safe to pass
#                       universally.
#                       NOTE: nothing in the current fenced-dynamic model writes
#                       {session}-main-scope.json (retired discovery artifact);
#                       without it this flag degrades to normal behavior.
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
# Optional 3rd arg `warn_as_error` (0|1, default 0): when 1 and the command
# exited 0, scan output for lint-warning lines and treat any match as a failure,
# so warnings flow through the same fix-loop as errors (closes the gap for node
# lint scripts without --max-warnings=0, biome's default warning severity, etc).
# The detector matches eslint `<file>:<line>:<col>  warning`, biome
# `warning[...]:`, golangci `warning:`, generic ` warn:` / ` warning:`. Build /
# typecheck phases pass warn_as_error=0 (build warnings are not the linter's domain).
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
          local msg="verify-build.sh: $label foreign-only (no in-scope file implicated); "
          msg+="--in-scope-only treats as clean, continuing to next phase"
          echo "$msg" >&2
          rm -f "$ERRORS_FILE"
          return 0
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

# F2: a lint failure implicating NO in-scope allowed_file is foreign /
# pre-existing debt, not this session's work. We still first-fail-stop (never
# fail open - masking a real in-scope regression is worse than a noisy foreign
# one), but append a greppable NOTE telling the orchestrator to verify in-scope
# lint/tsc/build separately (legacy scoped mode; {session}-main-scope.json has
# no live producer since the fenced-dynamic transition, so this branch is a
# no-op unless a caller supplies one). No main-scope.json / no jq ->
# no-op. Returns 0 if an in-scope allowed_file is implicated, 1 if the failure
# is entirely foreign (used by --in-scope-only).
annotate_foreign_lint() {
  local scope_json="$APEX_ACTIVE/${SESSION}-main-scope.json"
  command -v jq >/dev/null 2>&1 && [[ -f "$scope_json" ]] || return 0
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && grep -Fq -- "$f" "$TMP_OUT" && return 0
  done < <(jq -r '.allowed_files[]?' "$scope_json" 2>/dev/null || true)
  local note='## NOTE: no in-scope allowed_file implicated - lint failure appears foreign/pre-existing; '
  note+='orchestrator should verify in-scope lint/typecheck/build separately before treating the '
  note+='run as blocked (verify gate).'
  printf '%s\n' "$note" >> "$ERRORS_FILE"
  return 1
}

# Scope-isolated lint --fix pre-pass (node). A repo-wide `lint --fix` reformats
# files OUTSIDE allowed_files into the commit (recurring scope-drift -> spurious
# commit-time AskUserQuestion), so auto-fix ONLY the in-scope lintable files via the
# project-local eslint directly (the npm lint script's globs can't be narrowed
# by appending paths - eslint treats positionals as extra patterns). No scope
# json / jq / local eslint / in-scope JS-TS file -> no auto-fix at all, never a
# repo-wide pass; the canonical lint phase below still feeds the fix-loop. The
# `-f` guard skips git-root-relative paths unresolvable from cwd (no-op, no error).
scoped_lint_fix() {
  local scope_json="$APEX_ACTIVE/${SESSION}-main-scope.json"
  command -v jq >/dev/null 2>&1 && [[ -f "$scope_json" ]] || return 0
  local eslint_bin="node_modules/.bin/eslint"
  [[ -x "$eslint_bin" ]] || return 0
  local files=() f
  while IFS= read -r f; do
    [[ "$f" =~ \.(js|jsx|mjs|cjs|ts|tsx|mts|cts)$ && -f "$f" ]] && files+=("$f")
  done < <(jq -r '.allowed_files[]?' "$scope_json" 2>/dev/null || true)
  (( ${#files[@]} > 0 )) || return 0
  "$eslint_bin" --fix "${files[@]}" >/dev/null 2>&1 || true
}

# Cached space-padded list of npm script names (populated once when
# PROJECT_TYPE=node); membership is a portable bash substring test.
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

has_bin() { command -v "$1" >/dev/null 2>&1; }

# --- Docs-only fast-path ---
# When every file modified since the session fork point is documentation
# (*.md / *.markdown / *.txt under docs/** or top-level README/CHANGELOG), there
# is nothing to lint or build - skip the eslint/clippy/ruff binary lookup + the
# foreign-error noise a docs-only diff would otherwise trip.
MANIFEST_JSON="$APEX_ACTIVE/${SESSION}.json"
if [[ -f "$MANIFEST_JSON" ]] && command -v jq >/dev/null 2>&1; then
  BASE_BRANCH=$(jq -r .base_branch "$MANIFEST_JSON" 2>/dev/null || true)
  if [[ -n "$BASE_BRANCH" && "$BASE_BRANCH" != "null" ]]; then
    DIFF_ANCHOR=$(git merge-base "$BASE_BRANCH" HEAD 2>/dev/null || true)
    if [[ -n "$DIFF_ANCHOR" ]]; then
      CHANGED=$( {
        git diff --name-only "$DIFF_ANCHOR" 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
      } | sort -u)
      if [[ -n "$CHANGED" ]] && ! printf '%s\n' "$CHANGED" \
          | grep -vE '\.(md|markdown|txt|MD)$|^docs/|^CHANGELOG|^README' >/dev/null 2>&1; then
        echo "verify-build.sh: docs-only diff (no lint/build surface); skipping" >&2
        exit 0
      fi
    fi
  fi
fi

# --- Python venv bin resolution ---
# Greenfield-python projects install ruff/mypy/pytest into a local venv, not on
# the system PATH - a recurring gap where the lookups below (and the child
# verify-tests.sh) missed the tooling and forced a verify re-run. Prepend the
# first venv bin found so every downstream resolution is project-local. Names
# mirror the SKILL.md step-5 auto-force venv allowlist; the python probe
# confirms a real venv bin dir.
for _venv in .venv venv env; do
  if [[ -x "$PROJECT_ROOT/$_venv/bin/python" || -x "$PROJECT_ROOT/$_venv/bin/python3" ]]; then
    PATH="$PROJECT_ROOT/$_venv/bin:$PATH"; export PATH
    echo "verify-build.sh: prepended $_venv/bin to PATH (project venv)" >&2
    break
  fi
done

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

    # Build the run-prefix. `npm run --silent` suppresses the "> pkg@ver build"
    # header (noise the fixer doesn't need); pnpm/yarn/bun are clean by default.
    case "$PM" in
      npm)  RUN_PREFIX="npm run --silent" ;;
      pnpm) RUN_PREFIX="pnpm run" ;;
      yarn) RUN_PREFIX="yarn run" ;;
      bun)  RUN_PREFIX="bun run" ;;
    esac

    # Worktree dep bootstrap (Layer 3 defensive): node_modules missing means
    # mint-worktree.sh's dep symlink found nothing to link, or a non-/apex
    # caller is verifying a fresh clone. Install once with the PM's frozen-
    # lockfile equivalent so a real "lockfile drift" surfaces instead of a
    # masked "module not found"; failures feed the normal first-fail-stop.
    if [[ ! -d node_modules ]]; then
      case "$PM" in
        npm)  INSTALL_CMD="npm ci" ;;
        pnpm) INSTALL_CMD="pnpm install --frozen-lockfile" ;;
        yarn) INSTALL_CMD="yarn install --frozen-lockfile" ;;
        bun)  INSTALL_CMD="bun install --frozen-lockfile" ;;
      esac
      echo "verify-build.sh: node_modules missing; running $INSTALL_CMD" >&2
      bash -c "$INSTALL_CMD" >/dev/null 2>&1 \
        || echo "verify-build.sh: $INSTALL_CMD failed (continuing; lint/build will surface the real error)" >&2
    fi

    load_npm_scripts
    ran_anything=0
    # Order matters: lint -> typecheck -> build.
    # A typecheck failure usually cascades into build, so first-fail-stop keeps
    # the fix executor focused on the upstream cause.
    # Lint phase: scope-isolated `eslint --fix` pre-pass (scoped_lint_fix)
    # auto-resolves machine-fixable issues in the in-scope allowed_files before
    # the canonical lint runs - cuts fix-loop tokens without reformatting
    # out-of-scope files. Then warn_as_error=1 so eslint/biome warnings feed the
    # same fix-loop as errors (closes the gap for projects whose `lint` script
    # doesn't pass --max-warnings=0).
    for script in lint typecheck build; do
      if has_npm_script "$script"; then
        ran_anything=1
        if [[ "$script" == "lint" ]]; then
          scoped_lint_fix
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
