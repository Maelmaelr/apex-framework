---
name: admin-apex
description: Maintain, validate, commit, mirror, and push the APEX framework. Manual only.
---

# /admin-apex

Maintainer for the apex framework. `~/.claude` is the private source of truth; `/Users/mael/dev/apex-framework` is its public mirror. Every run ends with the same tail: Validate -> Commit -> Mirror.

## Scope

- `skills/apex`, `skills/apex-merge`, `skills/apex-init`, `skills/apex-git`, `skills/admin-apex`; `agents/executor.md` + `agents/apex-merge-resolver.md`; the hook scripts wired in `settings.json`; `content-budget.json`; the `skills/README.md` index.
- NOT project repos, NOT non-apex skills, NOT settings.json beyond the hook wiring.

## Flow

Sequence freely like a maintainer would - no fixed step march - but never skip the tail (4-6).

1. **Intake.** Read the request. Invoked without a specific ask -> run the audit below, report findings, and get user approval (AskUserQuestion) before applying anything that reshapes a contract or removes files.
2. **Audit** (as the task needs):
   - Dangling refs: grep skills/agents/settings.json for names of files, scripts, skills, or agents that no longer exist.
   - Doc-code consistency: each SKILL.md's named scripts, args, artifacts, and step contracts match what the scripts actually do; the hooks listed in `skills/README.md` match `settings.json`.
   - Budgets + health: covered by validate.sh (below); run it early when auditing.
3. **Edit.** Minimal diffs; doc and code reconciled in the same change (CLAUDE.md doc-code consistency rule). Work inline - the framework surface is small; spawn an `Explore` agent only for a genuinely wide read-only sweep.
4. **Validate.** `bash ~/.claude/skills/admin-apex/scripts/validate.sh` must pass: shell/python syntax, JSON parse, hook smoke runs (benign inputs must return allow), and doc word budgets. Fix and re-run on failure; cap 3 attempts, then surface with the error output.
5. **Commit (private).** From `~/.claude`: stage the framework paths you touched - never a blind `git add -A`, the repo carries private harness state - and commit `admin-apex: <summary>`.
6. **Mirror + push.** `bash ~/.claude/skills/admin-apex/scripts/mirror-to-dev.sh` - full reconciliation of the public allowlist: copies allowlisted files, deletes mirror files whose private source is gone (this is how a retired skill leaves the mirror), commits with the private HEAD message, pushes public then private. Set `APEX_MIRROR_NO_PUSH=1` for commit-only.

## Rails

- Never mirrored: `settings.json`, `CLAUDE.md`, `skills/README.md`, `skills/apex-git/` (personal), `tmp/`, and everything else outside the allowlist in mirror-to-dev.sh.
- Global rules apply in full: no `.env*` reads, AskUserQuestion before destructive operations, tool-output integrity.
- The framework deliberately has no VERSION file, no reflector, and no self-improvement loop. Do not reintroduce meta-machinery: a maintenance need is a direct edit in this run, not a new subsystem, log, or scheduled job.
