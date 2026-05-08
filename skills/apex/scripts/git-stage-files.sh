#!/usr/bin/env bash
# Step 12 git-stage helper: stage the apex-driven change set with a deterministic dotenv guard.
# Spec: apex-core.md step 12 ("per-file pre-filter" contract).
#
# Stages, per-file, the union of:
#   - git diff --name-only HEAD                 (tracked-modified, WT-only)
#   - git ls-files --others --exclude-standard  (untracked-non-ignored)
# HEAD-relative diff (NOT vs the baseline $HEAD_SHA) is deliberate: a sibling
# /apex session's commit can advance HEAD past our baseline, and using
# $HEAD_SHA as the diff base would surface the sibling's already-committed
# paths as "changed" and stage them under our session's commit. See
# inline rationale block at the diff-computation site.
#
# Filter (block-by-default for dotenv shapes; the only protection for `git add`
# of .env-shaped paths since `protect-env-hook.sh` covers Edit/Write only):
#   1. SKIP if basename matches `.env*` AND basename NOT in the template
#      allowlist `{.env.example, .env.sample, .env.template}`. Closed allowlist
#      catches .env.staging / .env.test / .env.ci / .envrc / etc. that a narrow
#      denylist would miss.
#   2. SKIP if `git check-ignore <path>` returns 0 (covers `.claude-tmp/` and
#      the project's `.gitignore`).
#
# Stages survivors via per-file `git add` (NEVER `git add -A`).
#
# Args:
#   --head-sha <sha>   required; baseline head_sha read from {session}-baseline.json
#   --session <token>  required; calling apex {session} (8-hex). Used to scope the
#                      cross-session filter: paths in OTHER sessions' main-scope
#                      allowed_files are skipped (concurrent-session contamination
#                      guard - mirrors apex-conflict-check.sh granularity).
#   --dry-run          optional; emits surviving paths to stdout WITHOUT staging
#                      (callers that only need the filtered list use this)
#
# Exit codes:
#   0  success - all survivors staged (or listed under --dry-run); 0 survivors is also success
#   1  git failure (status / add) - errors written to stderr
#   2  invocation error (bad args)

set -uo pipefail

HEAD_SHA=""
SESSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head-sha)
      HEAD_SHA="${2:-}"
      shift 2
      ;;
    --session)
      SESSION="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "git-stage-files.sh: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$HEAD_SHA" ]]; then
  echo "git-stage-files.sh: --head-sha is required" >&2
  exit 2
fi

if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "git-stage-files.sh: invalid head_sha shape: $HEAD_SHA (expected 7-40 char lowercase hex)" >&2
  exit 2
fi

if [[ -z "$SESSION" ]]; then
  echo "git-stage-files.sh: --session is required" >&2
  exit 2
fi

if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "git-stage-files.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2
  exit 2
fi

# Closed template allowlist - any other .env* basename is blocked. Keep in sync
# with `protect-env-hook.sh` (the analogous gate for Edit/Write).
is_env_template() {
  case "$1" in
    .env.example|.env.sample|.env.template) return 0 ;;
    *) return 1 ;;
  esac
}

# Compute change set. Both branches required: `git diff` excludes untracked, so
# a new file apex created via Write would otherwise never get staged.
#
# TRACKED diff base is HEAD (working-tree-only), NOT $HEAD_SHA. If a SIBLING
# /apex session commits between this session's step 8.0 baseline capture and
# this script's invocation, HEAD advances past $HEAD_SHA. `git diff $HEAD_SHA`
# would then surface the sibling's already-committed paths as "changed" and
# stage them under our session's commit (silent cross-session leak documented
# by reflectors 3c16319f + 7f9de350: text-preview.tsx, en.json, fr.json from
# session 084e7178 overwriting tokenCount threading). HEAD-relative diff
# excludes already-committed work (ours or sibling) and only stages genuinely
# uncommitted working-tree changes - which is the actual semantics of "stage
# what is dirty". $HEAD_SHA is preserved as a required arg for shape validation
# and downstream guards but is no longer the staging diff base.
TRACKED=$(git diff --name-only HEAD 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
CHANGE_SET=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | grep -v '^$' | sort -u)

# Cross-session contamination guard. Build the union of `allowed_files` from
# every OTHER active session's main-scope (excluding our own SESSION). Any
# path in CHANGE_SET that appears in that union is dropped before staging -
# that file belongs to a sibling /apex run, and committing it under our
# session's commit would silently steal their work. Mirrors the granularity
# of apex-conflict-check.sh (main-scope only).
APEX_ACTIVE=".claude-tmp/apex-active"
OTHER_SCOPE_FILES=""
if command -v jq >/dev/null 2>&1 && [[ -d "$APEX_ACTIVE" ]]; then
  shopt -s nullglob
  for scope in "$APEX_ACTIVE"/*-main-scope.json; do
    [[ -f "$scope" ]] || continue
    [[ "$scope" == *"$SESSION-main-scope.json" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      OTHER_SCOPE_FILES+="$f"$'\n'
    done < <(jq -r '.allowed_files[]?' "$scope" 2>/dev/null || true)
  done
  shopt -u nullglob
fi
OTHER_SCOPE_FILES=$(printf '%s' "$OTHER_SCOPE_FILES" | grep -v '^$' | sort -u || true)

# Pre-dirty filter. Read `pre_dirty` from {session}-baseline.json (captured at
# step 8.0). User-pre-existing WIP is never bundled into the apex commit, even
# when apex deliberately edited a pre-dirty file (the merged change stays dirty
# for the user to review and commit). Spec: apex-core.md step 12.
PRE_DIRTY_FILES=""
BASELINE_PATH="$APEX_ACTIVE/$SESSION-baseline.json"
if command -v jq >/dev/null 2>&1 && [[ -f "$BASELINE_PATH" ]]; then
  PRE_DIRTY_FILES=$(jq -r '.pre_dirty[]?' "$BASELINE_PATH" 2>/dev/null | sort -u || true)
fi

if [[ -z "$CHANGE_SET" ]]; then
  # Nothing changed since baseline. Not an error.
  exit 0
fi

rc=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  base=$(basename -- "$path")

  # Pre-dirty guard. Drop paths user already had dirty at step 8.0 baseline -
  # any apex edit on top of the user's WIP stays dirty for them to review.
  if [[ -n "$PRE_DIRTY_FILES" ]] && printf '%s\n' "$PRE_DIRTY_FILES" | grep -Fx -- "$path" >/dev/null 2>&1; then
    echo "git-stage-files.sh: skipping pre-dirty (user WIP at baseline): $path" >&2
    continue
  fi

  # Dotenv guard. Glob match `.env*` (literal dot + `env` prefix); template
  # allowlist is the only escape hatch.
  case "$base" in
    .env*)
      if ! is_env_template "$base"; then
        echo "git-stage-files.sh: skipping dotenv: $path" >&2
        continue
      fi
      ;;
  esac

  # gitignore guard. `git check-ignore` exits 0 if the path is ignored.
  if git check-ignore -q -- "$path" 2>/dev/null; then
    echo "git-stage-files.sh: skipping gitignored: $path" >&2
    continue
  fi

  # Cross-session guard. Drop paths claimed by another active session's
  # main-scope allowed_files (sibling /apex run owns this file). Also
  # actively unstage if the sibling pre-staged the path - 'continue' alone
  # leaves prior `git add` in the index, which would commit the contaminant
  # under our session.
  if [[ -n "$OTHER_SCOPE_FILES" ]] && printf '%s\n' "$OTHER_SCOPE_FILES" | grep -Fx -- "$path" >/dev/null 2>&1; then
    if git diff --cached --name-only 2>/dev/null | grep -Fx -- "$path" >/dev/null 2>&1; then
      git restore --staged -- "$path" 2>/dev/null || git reset HEAD -- "$path" >/dev/null 2>&1 || true
      echo "git-stage-files.sh: unstaged cross-session contaminant (sibling main-scope): $path" >&2
    else
      echo "git-stage-files.sh: skipping cross-session (claimed by sibling main-scope): $path" >&2
    fi
    continue
  fi

  if (( DRY_RUN )); then
    printf '%s\n' "$path"
    continue
  fi

  if ! git add -- "$path" 2>&1; then
    echo "git-stage-files.sh: git add failed: $path" >&2
    rc=1
  fi
done <<< "$CHANGE_SET"

exit $rc
