#!/usr/bin/env bash
# Mirror the public-eligible apex framework files from ~/.claude (private)
# to /Users/mael/dev/apex-framework (public), commit + push both repos.
# Invoked by /admin-apex as the final task, after the private commit lands.
#
# Full reconciliation, idempotent: allowlisted roots are synced verbatim -
# additions/updates copied, and mirror files whose private source is gone are
# deleted (this is how a retired skill or agent leaves the mirror). Everything
# outside the allowlist is private to ~/.claude and never touches the mirror.
#
# Allowlist (identity path mapping):
#   skills/apex/**  skills/admin-apex/**  skills/apex-merge/**  skills/apex-init/**
#   agents/*.md that exist privately
# Never mirrored: settings.json, CLAUDE.md, skills/README.md,
#   skills/apex-git/** (personal), tmp/, everything else outside the allowlist.
#
# Env overrides:
#   APEX_PRIVATE        default $HOME/.claude
#   APEX_FRAMEWORK_DEV  default /Users/mael/dev/apex-framework
#   APEX_MIRROR_NO_PUSH if set non-empty, commit-only (skip both pushes)
#
# Exit codes: 0 ok/nothing-to-do; 3 mirror missing; 5 public commit failed;
#             6 public push failed; 7 private push failed.
set -euo pipefail

PRIVATE="${APEX_PRIVATE:-$HOME/.claude}"
PUBLIC="${APEX_FRAMEWORK_DEV:-/Users/mael/dev/apex-framework}"
[[ -d "$PUBLIC/.git" ]] || { echo "FATAL: public mirror not a git repo: $PUBLIC" >&2; exit 3; }

ROOTS=(skills/apex skills/admin-apex skills/apex-merge skills/apex-init)

# Sync allowlisted skill roots: copy private -> public, delete public strays.
for root in "${ROOTS[@]}"; do
  if [[ -d "$PRIVATE/$root" ]]; then
    mkdir -p "$PUBLIC/$root"
    rsync -a --delete --exclude '__pycache__' "$PRIVATE/$root/" "$PUBLIC/$root/"
  elif [[ -d "$PUBLIC/$root" ]]; then
    rm -rf "$PUBLIC/$root"
  fi
done

# Agents: mirror every private agents/*.md; drop mirror agents with no source.
mkdir -p "$PUBLIC/agents"
for src_agent in "$PRIVATE"/agents/*.md; do
  [[ -e "$src_agent" ]] || continue
  cp -p "$src_agent" "$PUBLIC/agents/$(basename "$src_agent")"
done
for pub_agent in "$PUBLIC"/agents/*.md; do
  [[ -e "$pub_agent" ]] || continue
  [[ -f "$PRIVATE/agents/$(basename "$pub_agent")" ]] || rm -f "$pub_agent"
done

# Drain retired artifacts: top-level files and skills/ dirs the private tree
# no longer carries (skills present privately but denylisted - e.g. apex-git -
# were never mirrored; if one ever leaked, the private-dir guard keeps it
# until the private dir is gone too, which is acceptable for a mirror).
for stale in VERSION apex-core.md apex-core-overview.md; do
  [[ -f "$PRIVATE/$stale" ]] || rm -f "$PUBLIC/$stale"
done
for pub_skill in "$PUBLIC"/skills/*/; do
  [[ -d "$pub_skill" ]] || continue
  rel="skills/$(basename "$pub_skill")"
  [[ -d "$PRIVATE/$rel" ]] || rm -rf "$pub_skill"
done
find "$PUBLIC/skills" "$PUBLIC/agents" -type d -empty -not -path '*/.git*' -delete 2>/dev/null || true

git -C "$PUBLIC" add -A
if git -C "$PUBLIC" diff --cached --quiet; then
  echo "mirror already in sync; no public commit"
else
  msg=$(git -C "$PRIVATE" log -1 --pretty=%B)
  git -C "$PUBLIC" commit -m "$msg" || { echo "git commit failed in $PUBLIC" >&2; exit 5; }
  echo "mirror committed: $(git -C "$PUBLIC" log -1 --pretty='%h %s')"
fi

if [[ -z "${APEX_MIRROR_NO_PUSH:-}" ]]; then
  git -C "$PUBLIC" push origin "$(git -C "$PUBLIC" rev-parse --abbrev-ref HEAD)" \
    || { echo "push failed in $PUBLIC" >&2; exit 6; }
  git -C "$PRIVATE" push origin "$(git -C "$PRIVATE" rev-parse --abbrev-ref HEAD)" \
    || { echo "push failed in $PRIVATE" >&2; exit 7; }
  echo "pushed both repos."
else
  echo "push skipped (APEX_MIRROR_NO_PUSH set)."
fi
