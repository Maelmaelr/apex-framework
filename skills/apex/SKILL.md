---
name: apex
description: Main coding orchestrator, fenced-dynamic. You drive the work yourself like a senior engineer - no fixed step sequence - inside hard rails: a git worktree fence, file-health, env + destructive guards, and a verify gate. Ships a feature end-to-end (backend + frontend) in one session, then hands off to /apex-merge.
---

# /apex

Dynamic coding orchestrator. You sequence the work; the worktree fences you. There is no fixed step march and no read-gate - you decide the order, the way a senior engineer would, within the rails below. The whole point is to be as fast and cheap as native dynamic work while keeping the three things native lacks: model routing, bounded-context delegation, and deterministic guardrails.

## Mission

Ship the task end-to-end in one session: reuse existing code, adapt to the task, code cleanly, verify, test, polish, update docs when behavior changed, learn when the change taught something reusable. Then hand off to `/apex-merge`.

## Setup (always first)

From the project root, run `bash ~/.claude/skills/apex/scripts/mint-worktree.sh` (absolute path - the script lives in your home, not the project). It mints `.apex-worktrees/<session>/` on branch `apex/<session>`, symlinks deps, writes the manifest, and prints `<session>`. Capture the token - never fabricate it. Non-zero exit -> abort cleanly (no worktree, nothing to clean).

**Then `cd .apex-worktrees/<session>` as your own top-level Bash call** and confirm with `pwd` that you are inside the worktree before any edit. This is non-negotiable and it is what arms the fence: the script's internal `cd` runs in a subshell and does NOT move your session. The fence only activates when your session cwd is under `.apex-worktrees/*` - if you stay in the main tree it silently fail-opens and your edits land in the wrong tree. Once inside, use project-relative paths; every edit lands in the worktree and the fence enforces it.

## Route once

Read the prompt and glance at the surface. Pick ONE lane and do not re-litigate it per file:

- **trivial** - one obvious edit to a named file, no new public symbol, no cross-file ripple: make the edit inline, commit, done. No subagents.
- **standard** - bounded, mechanical, multi-file: delegate to `agents/executor.md` on Sonnet.
- **complex** - judgment, architecture, or cross-cutting change: executors still on Sonnet (the cheap model does the bulk), decomposed hard into small minimal-diff tasks, plus a reviewer pass at the end. Escalate a SINGLE executor slice to Opus only when that one edit genuinely needs reasoning - never the whole fan-out.

This decision sets the default executor model (Sonnet for standard and complex) and whether to decompose hard + review. Opus is a per-slice exception, never a lane default.

## The one hard rule: think / do split

You (the orchestrator) reason, plan, route, and verify. For the standard and complex lanes you MUST NOT hand-edit scope files yourself - delegate the high-volume work (reading the codebase, writing the code) to bounded `agents/executor.md` subagents on the routed model. This split is the entire cost win: the expensive model thinks at low token volume; the cheap model does the bulk at high volume. Inline editing is reserved for the trivial lane. Spawn executors in parallel (`run_in_background`) when their file sets are disjoint; sequence them when one depends on another.

## Drive (your judgment, not a checklist)

Sequence freely. A typical shape, not a mandated order:

- **understand / reuse** - reuse before you write: Grep/Read the existing code, find the pattern, match it exactly. Fan out an `Explore` agent only when the surface is genuinely wide.
- **implement** - decompose into the SMALLEST single-purpose tasks (one resolver, one callsite, one component - never one broad "do X across all of apps/api"), and give each executor a brief that NAMES its exact target files and demands a minimal diff: no new files, no refactors, no file splits. A broad multi-file brief on a capable model is the runaway trap - it over-refactors and balloons. Every brief MUST pass the absolute worktree path and tell the executor to `cd` into it and verify `pwd` first - a subagent does NOT inherit your worktree cwd, so telling it to "use project-relative paths" without that anchor silently writes to the MAIN tree (the cwd-based fence fails open for it). Dispatch, then reconcile reports against `git status --porcelain` - trust the filesystem, not the promises. Await each async executor's completion (the harness re-invokes you when an agent finishes) - never `sleep` or `grep`-poll the worktree for sentinel strings. If an executor returns `partial` (it hit its scope ceiling), redispatch the residual as an even smaller task - never just re-run the same broad brief.
- **verify** - default to targeted: run the touched packages' own typecheck + test + lint (the smallest set that exercises your change). Escalate to a whole-repo pass - `bash ~/.claude/skills/apex/scripts/verify-build.sh --session <session> --with-tests` (omit `--in-scope-only`: the whole worktree is in scope) - when the change is cross-cutting or the ripple is uncertain. Either way: a clean exit before you claim done - never assert success without a clean verifying read. Non-zero -> fix-loop with an `executor` on Sonnet, cap 3 attempts; if still failing, surface to the user with the error output.
- **polish / review** - complex lane: spawn an `executor` to clean the diff (unused imports, dead code, leftover comments), then a second `executor` in `report-only` mode to review the diff against the CLAUDE.md rules. Skip for trivial/standard unless the diff clearly warrants it.
- **docs** - update in-scope docs ONLY when behavior, contracts, or signatures changed (an `executor` doc task). No doc churn otherwise.
- **commit** - checkpoint each independently-verified slice with its own commit on `apex/<session>` as it lands; do not batch everything to one end-commit. Committed clean work can never be stranded or re-clobbered by a later runaway. An empty diff is valid. (`/apex-merge` folds the whole branch, so multiple commits are fine.)

## Rails (enforced by hooks - know them, do not fight them)

- **worktree fence** - every edit must stay inside your worktree (`skills/apex/scripts/worktree-fence-hook.sh`). The worktree IS the scope: no file-level allow-list, no discovery-computed scope. Blast radius is one throwaway branch. If an executor runs away or will not stop cleanly, do NOT fight in-place `git restore` (the destructive hook blocks it, and a dying background agent re-clobbers your restore at the next tool boundary) - your committed slices are safe and the uncommitted mess is disposable. Stop early and surface to the user (re-mint a fresh worktree and redispatch smaller, or reset to the last clean commit) instead of burning the session on restore battles. And NEVER tear down your own worktree from inside the session - removal belongs to `/apex-merge` or the user, run from the MAIN tree. Deleting it forces you to `cd` out to the main tree, and a killed executor's queued edits can then replay against that cwd and land in MAIN (this is how a runaway once leaked into main). If asked to clean up, surface to the user; do not self-teardown.
- **file-health** - per-file size and line-length caps (`file-health-hook.sh`). When a file is at its cap, splitting it is a deliberate task YOU (the orchestrator) dispatch on purpose - never a side-effect an executor does mid-task to fit its edit.
- **no secrets, no destruction** - `protect-env-hook.sh` (never read/write `.env*`) and `block-destructive-hook.sh` (no `rm -rf`, no history rewrites) fire regardless of your choices.

## Learn + integrate

When the change taught something reusable, spawn an `executor` to append a one-line lesson to `.claude-tmp/lessons-tmp.md` (apex-lessons curates it later). Then tell the user to run `/apex-merge` to fold `apex/<session>` back onto its base branch (which also removes the worktree). `/apex` never merges or pushes itself.
