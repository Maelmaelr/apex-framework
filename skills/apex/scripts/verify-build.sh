#!/usr/bin/env bash
# p1.2 / p2.3: project-aware lint + build verifier.
# Spec: apex-core.md p1.2 / p2.3.
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
# Args:
#   --session <token>  required, 8-char lowercase hex
#
# Exit codes:
#   0  clean (all available commands passed) OR no recognized manifest
#   1  one of the verify commands failed (errors file populated)
#   2  invocation error (bad args, malformed session token)

set -uo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION="${2:-}"
      shift 2
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
# On zero, return so the caller continues to the next command.
run_or_fail() {
  local label="$1"
  local cmd="$2"
  : > "$TMP_OUT"
  local rc=0
  bash -lc "$cmd" >"$TMP_OUT" 2>&1 || rc=$?
  if (( rc != 0 )); then
    {
      printf '## verify-build.sh: %s FAILED (exit %d)\n' "$label" "$rc"
      printf '## command: %s\n' "$cmd"
      printf '## cwd: %s\n' "$(pwd)"
      printf '## ----- output -----\n'
      cat "$TMP_OUT"
    } > "$ERRORS_FILE"
    echo "verify-build.sh: $label FAILED (exit $rc); errors -> $ERRORS_FILE" >&2
    exit 1
  fi
  echo "verify-build.sh: $label OK" >&2
}

# Returns 0 if package.json declares a script with the given name.
has_npm_script() {
  NAME="$1" python3 - <<'PY'
import json, os, sys
try:
    with open("package.json", "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
scripts = data.get("scripts") or {}
sys.exit(0 if os.environ["NAME"] in scripts else 1)
PY
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
    if   [[ -f bun.lockb       ]]; then PM="bun"
    elif [[ -f pnpm-lock.yaml  ]]; then PM="pnpm"
    elif [[ -f yarn.lock       ]]; then PM="yarn"
    else                                PM="npm"
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

    ran_anything=0
    # Order matters: lint -> typecheck -> build.
    # A typecheck failure usually cascades into build, so first-fail-stop keeps
    # the fix executor focused on the upstream cause.
    for script in lint typecheck build; do
      if has_npm_script "$script"; then
        ran_anything=1
        run_or_fail "$script ($PM)" "$RUN_PREFIX $script"
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
    if cargo clippy --version >/dev/null 2>&1; then
      run_or_fail "cargo clippy" "cargo clippy --quiet --all-targets -- -D warnings"
    fi
    run_or_fail "cargo check" "cargo check --quiet --all-targets"
    ;;

  python)
    ran_anything=0
    if has_bin ruff; then
      ran_anything=1
      run_or_fail "ruff check" "ruff check ."
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
    run_or_fail "go vet"   "go vet ./..."
    run_or_fail "go build" "go build ./..."
    ;;
esac

echo "verify-build.sh: clean" >&2
exit 0
