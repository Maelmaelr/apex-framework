#!/usr/bin/env bash
# Canonical "ignorable dirty path" allowlist used by apex-merge Step 5 (worktree
# auto-force classification). Ignorable = harness state, the apex lessons file, or
# a known auto-generated / locally-regenerated artifact (next-env.d.ts, .venv,
# data/model-specs) - matched on the path alone (git status prefix ignored, so
# untracked '??' regen files classify too). bash `case` globs match `*` across
# `/`, so the at-any-depth patterns below are intentional.
#
# Usage:
#   dirty-classify.sh --is-ignorable <path>   # exit 0 if ignorable, 1 if real source
set -euo pipefail

_is_ignorable() {
  case "$1" in
    # harness state (incl. .claude/settings*.json, .claude-tmp/*-traces/**):
    .claude/*|.claude-tmp/*|.apex-worktrees/*)          return 0 ;;
    lessons.md|*/lessons.md)                            return 0 ;; # apex lessons file
    next-env.d.ts|*/next-env.d.ts)                      return 0 ;; # Next.js build auto-gen
    data/model-specs/*.json|*/data/model-specs/*.json)  return 0 ;; # re-stamped model specs
    .venv/*|*/.venv/*|venv/*|*/venv/*|env/*|*/env/*)    return 0 ;; # python virtualenv
  esac
  return 1
}

case "${1:-}" in
  --is-ignorable)
    _is_ignorable "${2:-}" && exit 0 || exit 1 ;;
  *)
    echo "usage: dirty-classify.sh --is-ignorable <path>" >&2; exit 2 ;;
esac
