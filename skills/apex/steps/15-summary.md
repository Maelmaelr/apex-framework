# apex step 15 - Inline summary

Lazy-loaded contract for orchestrator step 15. Dispatched from `skills/apex/SKILL.md`
step 15; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. This file is the full per-step contract. Cross-cutting rules: `apex-core.md` ## Conventions; routing summary: `apex-core-overview.md`.

## Contract

Inline, fully deterministic (NO LLM hop, NO git audit pass, NO executive prose).

**15.0 Pre-emit cwd sweep** (canonical cd-back guard, user-driven - "apex sessions don't consistently go back to main on session end; only some do"). Sole owner of the post-/apex cd-back to the main worktree (the prior step-13 / step-14 mid-paragraph one-liners drifted across long-context runs and were collapsed into this single unconditional sub-step). Runs on every non-aborted path (mid-flow abort exits before step 15 and keeps its own cd at the abort site). Resolve MAIN from step-2 working memory and cd if not already there - idempotent:
```bash
MAIN=$(cd "$(dirname "$(dirname "$WORKTREE_PATH")")" 2>/dev/null && pwd -P)
[[ -n "$MAIN" && "$(pwd -P)" != "$MAIN" ]] && cd "$MAIN"
```
MAIN-resolution failure (worktree_path malformed, subtree already gone) -> leave cwd as-is and emit the summary anyway; the read is deterministic from `{session}-hypothesis.json` which step 13/14 preserved.

Read `{session}-hypothesis.json` (preserved by step 13/14) + the per-goal status map collected at step 8.3, plus step 12's recorded inline-commit outcome. Emit EXACTLY the following sections, in this order, and nothing else (no commit-creep / scope-overspill audit, no next-steps checklist, no closing prose):
- `# apex summary - session {session}` - the H1 title line verbatim; the session id lives here so no other section repeats it.
- **Original request** - `original_prompt` rendered verbatim (do NOT paraphrase, pad, or append the session id - it is already in the title).
- **Hypothesis vs reality** - ONE line: `matched` if reality matched the step-4 `hypothesis`, else `matched with gaps: <one short phrase>`. Do NOT restate the hypothesis text.
- **Root cause** - ONE line: verbatim `interpretation` field of the `alternatives[]` entry with `status: kept` from `{session}-hypothesis.json` (the agreed-upon cause selected at step 4). Emit `not stated` when no kept alternative exists. Deterministic read; no LLM synthesis. Complements `Hypothesis vs reality` by stating the concrete cause; the `matched with gaps:` phrase already flags any divergence.
- **Per-goal status** - first line `N/M goals passed` (`implemented` + `already-satisfied` over `len(goals)`); then ONE short line per goal: `<short goal label, <=8 words> - <status>`. A record of what was done, never a question. No hypothesis echo, no executor notes, no multi-line per-goal detail.
- **Mid-run notes** - emit ONLY when an executor returned a `MANUAL:`-prefixed line in dispatch-summary `notes`: list each such command verbatim, one per line, flagged as the sole user-run residual (destructive / prod / credential-gated). apex ran every other setup command the work produced (deps / migrations / seeders / codegen / regen) itself. Omit the entire section when there is no MANUAL residual (user-driven: apex left the user commands/migrations to run).
- **Result** - git actions only, from step 12's inline commit: `commit <short-sha> <subject>`, `push apex/{session} -> <remote>` (or `push: skipped` / `not pushed` when step 12 did not push). No file lists, no diffstat, no warnings.

**After emitting the summary, close the loop**: `TaskUpdate` task 15 -> `completed` as the final orchestrator action (the final step has no successor task to start, so without an explicit close the TaskList strands at `1 in progress` after `/apex` exits). Hypothesis cleanup is owned by `cleanup-session.sh`'s `git worktree remove` on the clean+no-commits-past-base branch (worktree-remove sweeps the whole worktree subtree atomically); on the keep branches (clean+commits or dirty) the hypothesis is preserved for `/apex-merge` to read as resolver context. `session-end-hook.sh` remains the idempotent fallback for aborts that bypass step 15. **Do NOT `ScheduleWakeup` / leave a `/loop` fallback wakeup**: apex runs end-to-end synchronously and its only background work (`run_in_background` executors, the step-13 reflector) is harness-tracked - the orchestrator is re-invoked automatically when that work finishes, so there is never untracked external state to poll. A fallback heartbeat scheduled while apex runs only fires uselessly after the session has already completed (wasted tokens); when apex is wrapped in a bare `/loop`, omit the wakeup at completion rather than leaving one armed (user-driven).
