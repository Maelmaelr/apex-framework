#!/usr/bin/env bash
# Purpose: Mirror this run's allowlisted dirty paths from ~/.claude (private)
#          to /Users/mael/dev/apex-framework (public), commit + push both repos.
# Spec: skills/admin-apex/SKILL.md task 10 (mirror + push)
#
# Per-run mirror (NOT a full reconciliation). Reads {run}-dirty-paths.txt and
# {run}-docs-changed.txt from .claude-tmp/admin-apex-active/, applies an
# allowlist (everything outside is private to ~/.claude and skipped), copies
# survivors into the public mirror with identity path mapping, stages + commits
# them with the same message as the just-made ~/.claude commit, then pushes
# the public repo first (more visible failure surface) and ~/.claude second.
#
# Allowlist (mirrored to public; identity path mapping):
#   - skills/apex/**
#   - skills/admin-apex/**
#   - skills/apex-improve/**            (self-improvement engine; closes the reflector loop)
#   - skills/apex-merge/**              (worktree-mode integration skill; merges apex/<session>
#                                        branches into recorded base)
#   - skills/apex-tech-watch/**         (weekly tech-watch fetcher; produces tech-updates.md)
#   - agents/**
#   - VERSION
#   - apex-core.md
#   - apex-core-overview.md
#
# Denylist (NEVER mirrored - private to ~/.claude or shape-incompatible):
#   - settings.json                     (private user hooks; portable equivalent lives in dev repo)
#   - CLAUDE.md                         (private global rules; user-specific PII)
#   - skills/README.md                  (internal index; dev has its own public README at root)
#   - skills/apex-fix/**                (private orchestration)
#   - skills/apex-git/**                (private orchestration: personal git wrapper)
#   - skills/apex-init/**               (private orchestration)
#   - skills/apex-file-health/**        (private orchestration)
#   - skills/apex-lessons/**            (private orchestration: extract + analyze)
#   - plugins/**                        (private; installed_plugins.json + known_marketplaces.json are user-specific)
#   - statusline/**                     (private; user-specific config + cached state)
#   - tmp/**                            (private; reflector log + per-machine scratch)
#   - everything else outside the allowlist
#
# Args:
#   $1   <run-token>  required, e.g. "b6c67024"
#
# Env overrides:
#   APEX_PRIVATE              default: $HOME/.claude
#   APEX_FRAMEWORK_DEV        default: /Users/mael/dev/apex-framework
#   APEX_MIRROR_NO_PUSH       if set non-empty, skip both pushes (commit-only)
#   APEX_MIRROR_COMMIT_RANGE  default: HEAD~1..HEAD (single-commit, current behavior).
#                             Override (e.g., HEAD~3..HEAD) for multi-commit runs:
#                             the public commit message becomes the concatenated
#                             messages of all private commits in the range, oldest
#                             first. Single-commit default preserves byte-identical
#                             behavior with the prior `git log -1 --pretty=%B` form.
# Pre-dirty spec-doc reconcile: top-level allowlisted spec docs (apex-core.md,
# apex-core-overview.md) are always swept and dedup-merged into the path set
# when their private-vs-public content differs - even when not listed in
# {run}-dirty-paths.txt. Covers spec-doc commits that landed outside an
# admin-apex run.
#
# Exit codes:
#   0  mirrored + pushed (or nothing-to-do)
#   2  bad args
#   3  public mirror dir not found
#   4  git add failed in public
#   5  git commit failed in public
#   6  git push failed in public
#   7  git push failed in private

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: mirror-to-dev.sh <run-token>" >&2
  exit 2
fi
RUN="$1"

PRIVATE="${APEX_PRIVATE:-$HOME/.claude}"
PUBLIC="${APEX_FRAMEWORK_DEV:-/Users/mael/dev/apex-framework}"

[[ -d "$PUBLIC/.git" ]] || { echo "FATAL: public mirror not a git repo: $PUBLIC" >&2; exit 3; }

ACTIVE="$PRIVATE/.claude-tmp/admin-apex-active"
DIRTY="$ACTIVE/${RUN}-dirty-paths.txt"
DOCS="$ACTIVE/${RUN}-docs-changed.txt"

# Static allowlist + dynamic extension: any skills/* or agents/* path created or
# renamed during THIS run is auto-added so a newly-created public-eligible skill
# is mirrored on the first run that introduced it. Reflector 5df5c184 saw the
# manual-allowlist-only model omit skills/apex-merge/ in the run that created
# it; the auto-extend below reads {run}-applied-ops.json for create/rename ops
# and unions their target paths into a per-run dynamic allowlist. The denylist
# (settings.json / CLAUDE.md / skills/apex-fix / apex-git / apex-init
# / apex-file-health / apex-lessons / README.md / plugins / statusline / tmp)
# always wins and is checked BEFORE the auto-extend.
DYNAMIC_ALLOWED=""
APPLIED="$ACTIVE/${RUN}-applied-ops.json"
if [[ -s "$APPLIED" ]]; then
  DYNAMIC_ALLOWED=$(python3 -c "
import json, sys, os
try:
    ops = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
paths = set()
for op in ops if isinstance(ops, list) else []:
    if not isinstance(op, dict):
        continue
    kind = op.get('kind', '')
    if kind in ('create', 'rename'):
        for key in ('target', 'rename_to'):
            v = op.get(key, '')
            if isinstance(v, str) and (v.startswith('skills/') or v.startswith('agents/')):
                paths.add(v)
print('\n'.join(sorted(paths)))
" "$APPLIED" 2>/dev/null || true)
fi

denied_by_static() {
  # Private orchestration skills + user-specific docs - NEVER mirrored even if
  # an op creates a file under them.
  case "$1" in
    settings.json|CLAUDE.md|skills/README.md) return 0 ;;
    skills/apex-fix/*|skills/apex-git/*|skills/apex-init/*|skills/apex-file-health/*|skills/apex-lessons/*) return 0 ;;
    plugins/*|statusline/*|tmp/*) return 0 ;;
    *) return 1 ;;
  esac
}

allowed() {
  if denied_by_static "$1"; then return 1; fi
  case "$1" in
    skills/apex/*|skills/admin-apex/*|skills/apex-improve/*|skills/apex-merge/*|\
    skills/apex-tech-watch/*|agents/*|VERSION|apex-core.md|apex-core-overview.md)
      return 0 ;;
  esac
  if [[ -n "$DYNAMIC_ALLOWED" ]]; then
    while IFS= read -r dyn; do
      [[ -z "$dyn" ]] && continue
      # Allow exact match OR the file lives under a dyn-allowed dir.
      if [[ "$1" == "$dyn" || "$1" == "$dyn"/* ]]; then return 0; fi
      # Or the new path's dir matches a dyn-allowed file's dir (e.g. dyn = skills/new-skill/SKILL.md
      # auto-extends to skills/new-skill/*).
      dyn_dir="${dyn%/*}/"
      if [[ "$1" == "$dyn_dir"* ]]; then return 0; fi
    done <<< "$DYNAMIC_ALLOWED"
  fi
  return 1
}

paths=()
while IFS= read -r line; do
  paths+=("$line")
done < <(cat "$DIRTY" "$DOCS" 2>/dev/null | awk 'NF' | sort -u)

# Always sweep top-level spec docs and include any with private-vs-public
# drift. Covers spec-doc commits that landed outside an admin-apex run.
for sp in apex-core.md apex-core-overview.md; do
  src="$PRIVATE/$sp"
  dst="$PUBLIC/$sp"
  [[ -f "$src" ]] || continue
  if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    already=0
    for ep in ${paths[@]+"${paths[@]}"}; do
      if [[ "$ep" == "$sp" ]]; then already=1; break; fi
    done
    if [[ $already -eq 0 ]]; then
      paths+=("$sp")
      echo "include (pre-dirty drift): $sp"
    fi
  fi
done

mirrored=()
# `${arr[@]+"${arr[@]}"}` keeps `set -u` happy on macOS bash 3.2 when arr is
# empty (manifests on the soft-skip path: no allowlisted paths to mirror).
for p in ${paths[@]+"${paths[@]}"}; do
  if ! allowed "$p"; then
    echo "skip (denylist or non-allowlisted): $p"
    continue
  fi
  src="$PRIVATE/$p"
  dst="$PUBLIC/$p"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    mirrored+=("$p")
  elif [[ -e "$dst" ]]; then
    rm -f "$dst"
    mirrored+=("$p")
  fi
done

if [[ ${#mirrored[@]} -eq 0 ]]; then
  echo "no allowlisted paths to mirror"
  if [[ -z "${APEX_MIRROR_NO_PUSH:-}" ]]; then
    ( cd "$PRIVATE" && git push origin "$(git rev-parse --abbrev-ref HEAD)" ) \
      || { echo "push failed in $PRIVATE" >&2; exit 7; }
  fi
  exit 0
fi

( cd "$PUBLIC" && git add -- "${mirrored[@]}" ) \
  || { echo "git add failed in $PUBLIC" >&2; exit 4; }

if ( cd "$PUBLIC" && git diff --cached --quiet ); then
  echo "mirrored ${#mirrored[@]} paths but no net change in $PUBLIC; skipping commit"
else
  RANGE="${APEX_MIRROR_COMMIT_RANGE:-HEAD~1..HEAD}"
  msg=$(cd "$PRIVATE" && git log "$RANGE" --pretty=%B --reverse)
  ( cd "$PUBLIC" && git commit -m "$msg" ) \
    || { echo "git commit failed in $PUBLIC" >&2; exit 5; }
fi

if [[ -z "${APEX_MIRROR_NO_PUSH:-}" ]]; then
  ( cd "$PUBLIC" && git push origin "$(git rev-parse --abbrev-ref HEAD)" ) \
    || { echo "push failed in $PUBLIC" >&2; exit 6; }
  ( cd "$PRIVATE" && git push origin "$(git rev-parse --abbrev-ref HEAD)" ) \
    || { echo "push failed in $PRIVATE" >&2; exit 7; }
  echo "mirrored ${#mirrored[@]} paths to $PUBLIC; pushed both repos."
else
  echo "mirrored ${#mirrored[@]} paths to $PUBLIC; push skipped (APEX_MIRROR_NO_PUSH set)."
fi
