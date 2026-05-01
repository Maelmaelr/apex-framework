#!/usr/bin/env bash
# p1.3 / p2.4 git.md helper: stage the apex-driven change set with a deterministic dotenv guard.
# Spec: apex-core.md p1.3 / p2.4 (git.md "per-file pre-filter" contract).
#
# Reads the baseline head_sha and stages, per-file, the union of:
#   - git diff --name-only $HEAD_SHA            (tracked-modified)
#   - git ls-files --others --exclude-standard  (untracked-non-ignored)
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
#   --dry-run          optional; emits surviving paths to stdout WITHOUT staging
#                      (callers that only need the filtered list use this)
#
# Exit codes:
#   0  success - all survivors staged (or listed under --dry-run); 0 survivors is also success
#   1  git failure (status / add) - errors written to stderr
#   2  invocation error (bad args)

set -uo pipefail

HEAD_SHA=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head-sha)
      HEAD_SHA="${2:-}"
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
TRACKED=$(git diff --name-only "$HEAD_SHA" 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
CHANGE_SET=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | grep -v '^$' | sort -u)

if [[ -z "$CHANGE_SET" ]]; then
  # Nothing changed since baseline. Not an error.
  exit 0
fi

rc=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  base=$(basename -- "$path")

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
