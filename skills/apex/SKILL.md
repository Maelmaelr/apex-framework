---
name: apex
description: Main coding orchestrator, fenced-dynamic. You drive the work yourself like a senior engineer - no fixed step sequence - inside hard rails: a git worktree fence, file-health, env + destructive guards, and a verify gate. Ships a feature end-to-end (backend + frontend) in one session, then hands off to /apex-merge.
---

# /apex

Dynamic coding orchestrator. You sequence the work; the worktree fences you. There is no fixed step march and no read-gate - you decide the order, the way a senior engineer would, within the rails below. The whole point is to be as fast and cheap as native dynamic work while keeping the three things native lacks: model routing, bounded-context delegation, and deterministic guardrails.

## Mission

Ship the task end-to-end in one session: reuse existing code, adapt to the task, code cleanly, verify, test, polish, update docs when behavior changed. Then hand off to `/apex-merge`.

## Setup (always first)

From the project root, run `bash ~/.claude/skills/apex/scripts/mint-worktree.sh` (absolute path - the script lives in your home, not the project). It mints `.apex-worktrees/<session>/` on branch `apex/<session>`, symlinks deps, writes the manifest, and prints `<session>`. Capture the token - never fabricate it. Non-zero exit -> abort cleanly (no worktree, nothing to clean).

**Then `cd .apex-worktrees/<session>` as your own top-level Bash call** and confirm with `pwd` that you are inside the worktree before any edit. This is non-negotiable and it is what cwd-arms the fence: the script's internal `cd` runs in a subshell and does NOT move your session. Mint also arms a session-record backstop (`~/.claude/tmp/apex-fence/{<cc_session_id>, pid-<claude-pid>}` = worktree root) so writes from a cwd that never entered the worktree are denied rather than silently landing in the main tree - a backstop, not the workflow: `cd` first. Once inside, use project-relative paths; every edit lands in the worktree and the fence enforces it.

## Route once

Read the prompt and glance at the surface. Pick ONE lane and do not re-litigate it per file:

- **trivial** - one obvious edit to a named file, no new public symbol, no cross-file ripple: make the edit inline, commit, done. No subagents.
- **mechanical** - the brief fully specifies the change and no judgment is left (renames, locale-key fills, boilerplate replication, apply-this-exact-pattern-to-N-files): delegate to `agents/executor.md` on **Haiku**. If writing the brief means deciding something the executor would otherwise have to re-decide, it is not mechanical - route standard.
- **standard** - bounded, multi-file, some local judgment: executors on **Sonnet**.
- **complex** - architecture or cross-cutting change: decompose hard into small minimal-diff tasks, executors on **Sonnet** for the bulk, plus a reviewer pass at the end. Escalate a SINGLE hardest slice to **Opus** only when that one edit genuinely needs deep reasoning - never the whole fan-out.

The lane sets the default executor model, but routing is per-dispatch: a complex session can still send its rename sweep to Haiku, its feature slices to Sonnet, and one gnarly slice to Opus. Default down, not up - when unsure between two tiers, take the cheaper one and let a `partial`/`failed` return trigger the escalation.

## The one hard rule: think / do split

You (the orchestrator) reason, plan, route, and verify. For the standard and complex lanes you MUST NOT hand-edit scope files yourself - delegate the high-volume work (reading the codebase, writing the code) to bounded `agents/executor.md` subagents on the routed model. This split is the entire cost win: the expensive model thinks at low token volume; the cheap model does the bulk at high volume. Inline editing is reserved for the trivial lane. Dispatch disjoint-file slices in PARALLEL by default - one message, multiple `run_in_background` spawns; reserve sequential dispatch for a real dependency (B edits what A creates, or B's spec covers A's code). Serial-dispatching independent slices is a silent cost bug: it stretches wall-clock to the SUM of every executor instead of the slowest one (one observed run ran 12 agents strictly serially - ~195 min of subagent time that was largely parallelizable).

## Drive (your judgment, not a checklist)

Sequence freely. A typical shape, not a mandated order:

- **understand / reuse** - reuse before you write: Grep/Read the existing code, find the pattern, match it exactly. Fan out an `Explore` agent only when the surface is genuinely wide - and pin it to `model: sonnet`; a read-only map does not need your tier, and Explore otherwise inherits Opus and doubles the cost of pure context-gathering.
- **implement** - decompose into the SMALLEST single-purpose tasks (one resolver, one callsite, one component - never one broad "do X across all of apps/api"), and give each executor a brief that NAMES its exact target files and demands a minimal diff: no new files, no refactors, no file splits. A broad multi-file brief is the runaway trap. Gate on the one signal you can see BEFORE dispatch - edit-target file count, not tokens: a brief naming more than ~6 edit targets, or spanning more than one layer (migration/model + endpoint logic + routes + tests + docs), is a vertical feature slice = several tasks - split it before dispatching (split by layer, or by disjoint file cluster, so the pieces parallelize). Output tokens will NOT warn you: a runaway holds moderate output while thrashing 300+ turns re-grepping and re-reading files it cannot hold in context - one observed 14-to-17-file "sharing backend" brief cost 30+ min and 450k peak context on a single executor. The tell is file count up front, turn-count and wall-clock after. Every brief MUST pass the absolute worktree path and tell the executor to `cd` into it and verify `pwd` first - a subagent does NOT inherit your worktree cwd, so telling it to "use project-relative paths" without that anchor targets the MAIN tree (the session-record fence denies those writes, and the task burns its slot on deny errors instead of working). Dispatch, then reconcile reports against `git status --porcelain` - trust the filesystem, not the promises. Await each async executor's completion (the harness re-invokes you when an agent finishes) - never `sleep` or `grep`-poll the worktree for sentinel strings. If an executor returns `partial` (it hit its scope ceiling), redispatch the residual as an even smaller task - never just re-run the same broad brief.
- **verify** - default to targeted: run the touched packages' own typecheck + test + lint (the smallest set that exercises your change). Escalate to a whole-repo pass - `bash ~/.claude/skills/apex/scripts/verify-build.sh --session <session> --with-tests` (omit `--in-scope-only`: the whole worktree is in scope) - when the change is cross-cutting or the ripple is uncertain. Either way: a clean exit before you claim done - never assert success without a clean verifying read. Non-zero -> fix-loop with an `executor` on Sonnet, cap 3 attempts; if still failing, surface to the user with the error output.
- **polish / review** - complex lane: spawn an `executor` to clean the diff (unused imports, dead code, leftover comments), then a second `executor` in `report-only` mode to review the diff against the CLAUDE.md rules. Skip for trivial/standard unless the diff clearly warrants it.
- **docs** - update in-scope docs ONLY when behavior, contracts, or signatures changed (an `executor` doc task). No doc churn otherwise.
- **commit** - checkpoint each independently-verified slice with its own commit on `apex/<session>` as it lands; do not batch everything to one end-commit. Committed clean work can never be stranded or re-clobbered by a later runaway. An empty diff is valid. (`/apex-merge` folds the whole branch, so multiple commits are fine.)

## Rails (enforced by hooks - know them, do not fight them)

- **worktree fence** - every edit must stay inside your worktree (`skills/apex/scripts/worktree-fence-hook.sh`). The worktree IS the scope: no file-level allow-list, no discovery-computed scope. Blast radius is one throwaway branch. If an executor runs away or will not stop cleanly, do NOT fight in-place `git restore` (the destructive hook blocks it, and a dying background agent re-clobbers your restore at the next tool boundary) - your committed slices are safe and the uncommitted mess is disposable. Stop early and surface to the user (re-mint a fresh worktree and redispatch smaller, or reset to the last clean commit) instead of burning the session on restore battles. And NEVER tear down your own worktree from inside the session - removal belongs to `/apex-merge` or the user, run from the MAIN tree. Deleting it forces you to `cd` out to the main tree, and a killed executor's queued edits can then replay against that cwd and target MAIN (the session-record fence denies them only while the worktree still exists - teardown stales the record, so keeping the worktree up IS the guard). If asked to clean up, surface to the user; do not self-teardown.
- **file-health** - per-file size and line-length caps (`file-health-hook.sh`). When a file is at its cap, splitting it is a deliberate task YOU (the orchestrator) dispatch on purpose - never a side-effect an executor does mid-task to fit its edit.
- **no secrets, no destruction** - `protect-env-hook.sh` (never read/write `.env*`) and `block-destructive-hook.sh` (no `rm -rf`, no history rewrites) fire regardless of your choices.

## Hand off

Before you hand off, close the loop on what you did NOT ship. A run rarely fixes everything in one shot - you defer design decisions you must not blind-patch, findings you scoped out, follow-ups, "2 things left to add", "what I didn't cover". Do NOT just list them and stop for the user to ask. Automatically draft a concrete follow-up plan for that deferred set - short and phased, ordered by ROI, naming the target files and the one trap per phase - and commit it as a plan doc on `apex/<session>` so it lands on the base branch through the merge. Reach for `AskUserQuestion` only when a decision genuinely shapes the plan (which approach, or implement-now vs leave-as-plan) - never inline text questions, and never block on it when the plan is obvious. If nothing was deferred, say so in one line and move on.

Then tell the user to run `/apex-merge` to fold `apex/<session>` back onto its base branch (which also removes the worktree). `/apex` never merges or pushes itself.
