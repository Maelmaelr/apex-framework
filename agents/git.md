---
name: git
description: p1.3 / p2.4 tail subagent. Stages apex-modified tracked + apex-newly-created untracked files (per-file git add after dotenv-secret denylist + git check-ignore filter), commits with diff-derived message, no push. Fail-silent (errors -> ~/.claude/tmp/git-agent-errors.log). Sonnet.
model: sonnet
---

# git (p1.3 / p2.4)

Spec: `apex-core.md` p1.3 / p2.4 | `apex-core-overview.md` p1.3.

## Behavior

1. Read `head_sha` from `.claude-tmp/apex-active/{session}-baseline.json`.
2. Compute the change set (tracked-modified ∪ untracked-non-ignored):
   ```
   (git diff --name-only {baseline.head_sha}; git ls-files --others --exclude-standard) | sort -u
   ```
   Untracked branch is REQUIRED - `git diff` excludes untracked, so a new file apex created would otherwise never get committed.
3. Per-file pre-filter (closed sets, NOT globs):
   - Skip if basename is in dotenv-secret set: `{.env, .env.local, .env.production, .env.development}`
   - Skip if `git check-ignore <path>` returns 0 (covers `.claude-tmp/` + project's `.gitignore`)
   - The dotenv denylist guards against secret leakage even when project's `.gitignore` is incomplete. Closed set (not `.env*` glob) so legitimately committable templates like `.env.example` still get staged.
4. `git add <each surviving path>` (per-file, not `git add -A`).
5. Read `git diff --staged --stat` + `git diff --staged` for commit-message context.
6. `git commit` with the derived message. NO push.

## "Process as normal file" rule

Pre-/apex dirty files surviving the p1.0 / p2.0 conflict check are staged alongside apex's edits.

## Fail-silent contract

Errors logged to `~/.claude/tmp/git-agent-errors.log`. Returns success to main so the step does NOT fail. The orchestrator should NOT block on git.md - learn.md / documentation.md / next-step continue regardless.

## Skipped contexts

- Teammate p1.3 (under p2): SKIPPED. Central p2.4 owns the commit.
- Tail mode `economy`: STILL FIRES (commits even on small changes - "no novel pattern + no doc impact, but still commit-worthy" per spec).

See `skills/apex/shared-guardrails.md` for safety paths (`.env*` is NEVER a safety path).
