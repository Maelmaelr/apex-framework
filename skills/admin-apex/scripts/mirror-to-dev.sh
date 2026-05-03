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
#   - skills/apex-eod/**                (private orchestration: chains private skills)
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

allowed() {
  case "$1" in
    skills/apex/*|skills/admin-apex/*|skills/apex-improve/*|skills/apex-tech-watch/*|agents/*|VERSION|apex-core.md|apex-core-overview.md)
      return 0 ;;
    *) return 1 ;;
  esac
}

paths=()
while IFS= read -r line; do
  paths+=("$line")
done < <(cat "$DIRTY" "$DOCS" 2>/dev/null | awk 'NF' | sort -u)

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
