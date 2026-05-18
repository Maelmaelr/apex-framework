#!/usr/bin/env bash
# Step 12 build-and-commit helper: assemble the apex-driven commit from this
# session's OWN authoritative file manifest, via a session-private git index,
# and land it with a compare-and-swap ref update + plain push.
# Spec: apex-core.md step 12.
#
# WHY THIS IS AN ALLOWLIST, NOT A WORKING-TREE SCAN
# -------------------------------------------------
# The previous implementation staged a working-tree diff and then ran a
# denylist of sibling-claimed paths through it. That design failed OPEN: when a
# concurrent /apex session's main-scope.json was not yet on disk at the moment
# this script ran, the sibling's in-progress files were invisible to the
# denylist and got committed under THIS session's commit, while this session's
# own fix files were simultaneously dropped by an over-broad filter (the
# recurring cross-session contamination failure mode; reflector cluster
# 6714d9ba / 460877e7 / 72418039 / fad39712 / 17645693 / 3c16319f / 7f9de350 /
# 8418c06e / 5c32d3e2 and the documented race note that the denylist "is only
# as effective as the sibling's main-scope.json being on disk").
#
# This version inverts the data flow: the commit is built from the union of
# THIS session's own `allowed_files` + executor `files_touched` + a dirty
# VERSION (the authoritative "what this session produced" manifest). A sibling
# session's file is structurally incapable of entering this commit because it
# is not on this session's manifest - independent of whether the sibling's
# scope artifact exists yet. This session's own files cannot be silently
# dropped because they are on the manifest by construction. Fail-CLOSED: with
# no manifest source at all, nothing is committed (never the whole tree).
#
# WHY A PRIVATE INDEX + commit-tree + CAS update-ref
# --------------------------------------------------
# Concurrent sessions share one .git/index and one HEAD. `git add` + porcelain
# `git commit` race on both. This script stages into a per-invocation
# GIT_INDEX_FILE (sibling `git add` can never interleave), builds the commit
# with `git commit-tree` parented on the LIVE branch tip (never a stale
# baseline - seeding from a stale tree silently reverts a sibling's just-landed
# work), and moves the branch ref with the 3-arg compare-and-swap form of
# `git update-ref` (a concurrent ref move fails the CAS; we re-read the new tip
# and rebuild, bounded retry - lock-free, portable, no flock dependency since
# macOS ships no flock(1)). The shared working tree is never modified, so
# sibling/user dirty state is preserved.
#
# Stages, from the manifest, the subset that is actually dirty:
#   dirty = (git diff --name-only HEAD; git ls-files --others --exclude-standard)
#   stage = manifest INTERSECT dirty, minus the guards below.
#
# Guards (defense in depth; the allowlist already excludes foreign paths):
#   1. pre-dirty: drop paths in {session}-baseline.json:pre_dirty UNLESS the
#      path is also in our own allowed_files (in-scope pre-dirty is
#      apex-intentional - sibling /apex leftover or user-staged hand-off, not
#      WIP to protect; reflector 8418c06e).
#   2. dotenv: SKIP basenames matching `.env*` not in the template allowlist
#      {.env.example,.env.sample,.env.template} (the only `git add` protection
#      for .env shapes; mirrors protect-env-hook.sh which covers Edit/Write).
#   3. gitignore: SKIP if `git check-ignore` returns 0.
#
# Args:
#   --head-sha <sha>   required; accepted and shape-validated for caller-
#                      signature stability (agents/git-sync.md + apex-core.md
#                      step 12 always pass it). NOT consumed by this script:
#                      the pre-dirty/baseline read is keyed off --session
#                      ({session}-baseline.json), and the staging base is the
#                      live branch tip - never this value.
#   --session <token>  required; calling apex {session} (8-hex). Selects the
#                      own-scope manifest + baseline + dispatch-summary.
#   --message <msg>    required unless --dry-run; commit message. The caller
#                      (agents/git-sync.md) drafts it from the working-tree
#                      diff BEFORE this script runs, because staging is private
#                      (no shared `git diff --staged` to draft from post-hoc).
#   --dry-run          optional; print the resolved stage set to stdout and
#                      exit WITHOUT building/committing/pushing.
#
# Stdout (machine-readable, one token line first):
#   COMMIT <full-sha>          commit landed (push result on the next line:
#   PUSH ok|fail|skipped       ok / non-fast-forward-or-no-upstream / detached)
#   NOOP                       manifest produced nothing dirty to commit
#   SCOPE-GUARD-DISABLED       no manifest source (no main-scope.json AND no
#                              dispatch-summary.json), OR a source exists but
#                              jq is unavailable to parse it; nothing
#                              committed. Caller MUST treat as abort
#                              (fail-closed).
#   <paths...>                 under --dry-run only: the resolved stage set.
#
# Exit codes:
#   0  success / NOOP / SCOPE-GUARD-DISABLED / dry-run (all non-error)
#   1  git failure (read-tree / write-tree / commit-tree / ref CAS exhausted)
#   2  invocation error (bad args)

set -uo pipefail

HEAD_SHA=""
SESSION=""
MESSAGE=""
DRY_RUN=0
HAVE_MESSAGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head-sha) HEAD_SHA="${2:-}"; shift 2 ;;
    --session)  SESSION="${2:-}"; shift 2 ;;
    --message)  MESSAGE="${2:-}"; HAVE_MESSAGE=1; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    *) echo "git-stage-files.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HEAD_SHA" ]]; then
  echo "git-stage-files.sh: --head-sha is required" >&2; exit 2
fi
if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "git-stage-files.sh: invalid head_sha shape: $HEAD_SHA (expected 7-40 char lowercase hex)" >&2; exit 2
fi
if [[ -z "$SESSION" ]]; then
  echo "git-stage-files.sh: --session is required" >&2; exit 2
fi
if [[ ! "$SESSION" =~ ^[0-9a-f]{8}$ ]]; then
  echo "git-stage-files.sh: invalid session token shape: $SESSION (expected 8-char lowercase hex)" >&2; exit 2
fi
if (( ! DRY_RUN )) && (( ! HAVE_MESSAGE )); then
  echo "git-stage-files.sh: --message is required (unless --dry-run)" >&2; exit 2
fi

APEX_ACTIVE=".claude-tmp/apex-active"
OWN_SCOPE_PATH="$APEX_ACTIVE/$SESSION-main-scope.json"
BASELINE_PATH="$APEX_ACTIVE/$SESSION-baseline.json"
DISPATCH_PATH="$APEX_ACTIVE/$SESSION-traces/execute/dispatch-summary.json"
ERR_LOG="$HOME/.claude/tmp/git-agent-errors.log"

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

is_env_template() {
  case "$1" in
    .env.example|.env.sample|.env.template) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Build the authoritative manifest (the allowlist) --------------------
# own allowed_files
OWN_SCOPE_FILES=""
if (( have_jq )) && [[ -f "$OWN_SCOPE_PATH" ]]; then
  OWN_SCOPE_FILES=$(jq -r '.allowed_files[]?' "$OWN_SCOPE_PATH" 2>/dev/null | grep -v '^$' | sort -u || true)
fi

# executor files_touched (recursive: tolerates JSON array, single object, or
# NDJSON of executor returns - matches agents/git-sync.md's documented read).
TOUCHED_FILES=""
if (( have_jq )) && [[ -f "$DISPATCH_PATH" ]]; then
  TOUCHED_FILES=$(jq -r '.. | .files_touched? // empty | .[]?' "$DISPATCH_PATH" 2>/dev/null | grep -v '^$' | sort -u || true)
fi

HAVE_MANIFEST_SOURCE=0
[[ -f "$OWN_SCOPE_PATH" || -f "$DISPATCH_PATH" ]] && HAVE_MANIFEST_SOURCE=1

# Fail-closed: with no manifest source there is no authoritative "our files"
# set. The previous implementation fell OPEN here (staged the whole working
# tree, filtered by a denylist) - the exact cross-session contamination path.
# Refuse to commit instead. agents/git-sync.md treats this token as abort.
if (( ! HAVE_MANIFEST_SOURCE )); then
  echo "git-stage-files.sh: SCOPE-GUARD-DISABLED no manifest source (neither $OWN_SCOPE_PATH nor $DISPATCH_PATH); refusing to build an unscoped commit" >&2
  echo "SCOPE-GUARD-DISABLED"
  exit 0
fi

# Fail-closed #2: a manifest source exists on disk but jq is unavailable, so
# the authoritative allowlist cannot be parsed at all. Without jq,
# OWN_SCOPE_FILES and TOUCHED_FILES are empty, the no-source guard above does
# NOT fire (the files exist), and only a dirty VERSION would be staged -
# silently dropping this session's own fix code (the original incident's
# second symptom). The fail-closed guarantee must not be jq-conditional:
# refuse rather than commit an unparseable-manifest subset.
if (( ! have_jq )); then
  echo "git-stage-files.sh: SCOPE-GUARD-DISABLED jq unavailable; cannot parse the authoritative manifest ($OWN_SCOPE_PATH / $DISPATCH_PATH); refusing to build a partially-scoped commit" >&2
  echo "SCOPE-GUARD-DISABLED"
  exit 0
fi

MANIFEST=$(printf '%s\n%s\n' "$OWN_SCOPE_FILES" "$TOUCHED_FILES" | grep -v '^$' | sort -u || true)

# ---- Intersect with the actually-dirty working tree ----------------------
TRACKED=$(git diff --name-only HEAD 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
DIRTY=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | grep -v '^$' | sort -u || true)

# A dirty VERSION (any depth, basename match) is part of this session's output:
# git-sync.md runs bump-version.sh BEFORE this script, so VERSION is dirty by
# now and is authoritative even if absent from allowed_files (reflector
# 5cdc8eb0: VERSION bumped on disk but not committed). Add such paths to the
# manifest. No blanket docs/** or README pass: legitimate docs reach the commit
# via allowed_files (pre-coordinated) or files_touched; the old blanket pass
# was itself a leak (reflector da97c3c1).
VERSION_DIRTY=""
while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  [[ "$(basename -- "$d")" == "VERSION" ]] && VERSION_DIRTY+="$d"$'\n'
done <<< "$DIRTY"
if [[ -n "$VERSION_DIRTY" ]]; then
  MANIFEST=$(printf '%s\n%s\n' "$MANIFEST" "$VERSION_DIRTY" | grep -v '^$' | sort -u || true)
fi

# pre-dirty (user WIP at step-8 baseline)
PRE_DIRTY_FILES=""
if (( have_jq )) && [[ -f "$BASELINE_PATH" ]]; then
  PRE_DIRTY_FILES=$(jq -r '.pre_dirty[]?' "$BASELINE_PATH" 2>/dev/null | grep -v '^$' | sort -u || true)
fi

# stage set = MANIFEST INTERSECT DIRTY, minus guards
STAGE_SET=""
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  # must be on the manifest (the allowlist)
  printf '%s\n' "$MANIFEST" | grep -Fxq -- "$path" || continue
  base=$(basename -- "$path")

  # pre-dirty guard (own-scope exception, reflector 8418c06e)
  if [[ -n "$PRE_DIRTY_FILES" ]] && printf '%s\n' "$PRE_DIRTY_FILES" | grep -Fxq -- "$path"; then
    if ! { [[ -n "$OWN_SCOPE_FILES" ]] && printf '%s\n' "$OWN_SCOPE_FILES" | grep -Fxq -- "$path"; }; then
      echo "git-stage-files.sh: skipping pre-dirty (user WIP at baseline): $path" >&2
      continue
    fi
  fi

  # dotenv guard
  case "$base" in
    .env*)
      if ! is_env_template "$base"; then
        echo "git-stage-files.sh: skipping dotenv: $path" >&2
        continue
      fi
      ;;
  esac

  # gitignore guard
  if git check-ignore -q -- "$path" 2>/dev/null; then
    echo "git-stage-files.sh: skipping gitignored: $path" >&2
    continue
  fi

  STAGE_SET+="$path"$'\n'
done <<< "$DIRTY"
STAGE_SET=$(printf '%s' "$STAGE_SET" | grep -v '^$' || true)

if (( DRY_RUN )); then
  [[ -n "$STAGE_SET" ]] && printf '%s\n' "$STAGE_SET"
  exit 0
fi

if [[ -z "$STAGE_SET" ]]; then
  echo "NOOP"
  exit 0
fi

# ---- Resolve target ref --------------------------------------------------
BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [[ -n "$BRANCH" ]]; then
  TARGET_REF="refs/heads/$BRANCH"
  CAN_PUSH=1
else
  TARGET_REF="HEAD"   # detached: move HEAD itself, do not push
  CAN_PUSH=0
fi

# ---- Private-index build + CAS ref update (bounded retry) -----------------
PRIV_IDX="$(mktemp "${TMPDIR:-/tmp}/apex-idx.$SESSION.XXXXXX")" || {
  echo "git-stage-files.sh: mktemp failed for private index" >&2; exit 1
}
cleanup() { rm -f "$PRIV_IDX"; }
trap cleanup EXIT

NEW_COMMIT=""
TIP=""
attempt=0
MAX_ATTEMPTS=5
while (( attempt < MAX_ATTEMPTS )); do
  attempt=$((attempt + 1))
  TIP=$(git rev-parse --verify HEAD 2>/dev/null || true)
  if [[ -z "$TIP" ]]; then
    echo "git-stage-files.sh: cannot resolve HEAD" >&2; exit 1
  fi

  : > "$PRIV_IDX"
  if ! GIT_INDEX_FILE="$PRIV_IDX" git read-tree "$TIP" 2>/dev/null; then
    echo "git-stage-files.sh: read-tree failed at $TIP" >&2; exit 1
  fi

  add_rc=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # `git add` records modifications, additions AND deletions, so a manifest
    # path the executor deleted is staged correctly.
    if ! GIT_INDEX_FILE="$PRIV_IDX" git add -- "$path" 2>/dev/null; then
      echo "git-stage-files.sh: git add failed (private index): $path" >&2
      add_rc=1
    fi
  done <<< "$STAGE_SET"
  (( add_rc )) && exit 1

  TREE=$(GIT_INDEX_FILE="$PRIV_IDX" git write-tree 2>/dev/null || true)
  if [[ -z "$TREE" ]]; then
    echo "git-stage-files.sh: write-tree failed" >&2; exit 1
  fi

  # No-op guard: identical to the tip tree means nothing of ours actually
  # changed relative to HEAD (e.g. all executors already-satisfied).
  TIP_TREE=$(git rev-parse --verify "$TIP^{tree}" 2>/dev/null || true)
  if [[ -n "$TIP_TREE" && "$TREE" == "$TIP_TREE" ]]; then
    echo "NOOP"
    exit 0
  fi

  NEW_COMMIT=$(GIT_INDEX_FILE="$PRIV_IDX" git commit-tree "$TREE" -p "$TIP" -m "$MESSAGE" 2>/dev/null || true)
  if [[ -z "$NEW_COMMIT" ]]; then
    echo "git-stage-files.sh: commit-tree failed" >&2; exit 1
  fi

  # 3-arg update-ref = compare-and-swap. If a sibling moved the ref since our
  # `git rev-parse HEAD`, this fails atomically and we rebuild from the new
  # tip (re-reading it picks up the sibling's just-landed files, so we never
  # revert their work).
  if git update-ref "$TARGET_REF" "$NEW_COMMIT" "$TIP" 2>/dev/null; then
    break
  fi
  NEW_COMMIT=""
  sleep "0.$(( (RANDOM % 5) + 1 ))"
done

if [[ -z "$NEW_COMMIT" ]]; then
  echo "git-stage-files.sh: ref CAS exhausted after $MAX_ATTEMPTS attempts ($TARGET_REF moved by concurrent sessions)" >&2
  exit 1
fi

# Refresh the SHARED index for OUR committed paths only. update-ref moved HEAD
# but left the shared .git/index at the pre-commit snapshot; without this a
# sibling's `git status`/`git diff --cached` would show our committed paths as
# phantom staged deletions. Scoped to STAGE_SET so sibling/user shared-index
# state is untouched. Working tree is never modified by anything above.
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  git reset -q HEAD -- "$path" 2>/dev/null || true
done <<< "$STAGE_SET"

echo "COMMIT $NEW_COMMIT"

# ---- Push (plain; never --force, never auto-set-upstream; fail-silent) ----
if (( ! CAN_PUSH )); then
  echo "PUSH skipped"
  exit 0
fi
if git push 2>>"$ERR_LOG"; then
  echo "PUSH ok"
else
  echo "ERROR: session=$SESSION push failed (no upstream / non-fast-forward); commit $NEW_COMMIT is local-only" >> "$ERR_LOG"
  echo "PUSH fail"
fi
exit 0
