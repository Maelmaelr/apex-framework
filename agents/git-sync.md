---
name: git-sync
description: Step 12 VERSION bump + git stage / commit / push. Reads diff, classifies minor|patch (never major), drafts commit message, runs bump-version.sh + git-stage-files.sh + commit + push. Returns success/error. Subagents do NOT inherit working memory - all inputs come via spawn prompt.
model: haiku
---

# git-sync (step 12)

Spec: `apex-core.md` step 12.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

## Spawn-prompt inputs (caller propagates explicitly)

Subagents do NOT inherit working memory; the orchestrator MUST propagate every input below explicitly at the spawn site.

- `session` - 8-char hex token (for `git-stage-files.sh --session`).
- `baseline_head_sha` - git rev from `{session}-baseline.json` (for `git-stage-files.sh --head-sha` + diff range).
- `version_path` - `<project-root>/VERSION` (vX.Y.Z; missing file -> skip bump, still proceed to git stage / commit / push).

## Procedure

1. **Read VERSION**: open `version_path`. Expect `vX.Y.Z` (tolerate missing-`v` prefix and trailing newlines). Missing file = silent skip of the bump step (proceed to step 4).

2. **Classify diff** -> `minor` | `patch`. Read `git diff {baseline_head_sha}` and `git diff --staged --stat`. **Never `major`** (major is user-set only; if a project needs a major bump the user edits VERSION manually outside /apex).
   - **minor**: new feature, new public symbol / route / component, additive, OR breaking API change (removed/renamed public symbol, contract change, schema migration).
   - **patch**: bug fix, refactor, tweak, internal-only change.

3. **Bump VERSION**: `bash skills/apex/scripts/bump-version.sh --kind {minor|patch}` (increments matching segment; resets patch=0 on minor; writes back to VERSION).

4. **Draft commit message**: freeform from diff context (`git diff --staged --stat` + `git diff --staged`); VERSION bump may be referenced in title.

5. **Single chained git command** (one Bash call):
   ```
   bash skills/apex/scripts/git-stage-files.sh --head-sha {baseline_head_sha} --session {session} && git commit -m "<message>" && git push
   ```
   `git-stage-files.sh` owns the change-set + filter pipeline (pre-dirty / dotenv / check-ignore / cross-session). Push fail-silent (errors -> `~/.claude/tmp/git-agent-errors.log`); never `--force`, never auto-set-upstream.

6. **Files-touched sanity check** (best-effort, non-blocking): read `.claude-tmp/apex-active/{session}-traces/execute/dispatch-summary.json` (absent on trivial path -> skip); collect the union of `files_touched[]` across executor returns; for each path NOT in `git diff --staged --name-only` AND NOT in `{baseline.pre_dirty}`, append one line to `~/.claude/tmp/git-agent-errors.log`: `WARN: session={session} files_touched={path} not staged (filter: pre-dirty / dotenv / check-ignore / cross-session)`. Reflector 6dad99bf surfaced the symptom: implementation files reported by executors did not land staged while tests did. Sanity check arms the next /apex-improve to investigate; never blocks the return.

## Return to caller

`{status: "ok" | "push-fail" | "skip-no-version", commit_sha: "<sha-or-empty>", bump_kind: "minor" | "patch" | "none"}`. NEVER the diff body.

## What this agent does NOT do

- Does NOT pick `major` (user-set only).
- Does NOT auto-set-upstream or `--force` push.
- Does NOT touch project app code.
- Does NOT inherit working memory; all inputs flow through the spawn prompt.

See `apex-core.md` step 12 / Conventions for the full contract; `skills/apex/scripts/bump-version.sh` and `git-stage-files.sh` for the underlying scripts.
