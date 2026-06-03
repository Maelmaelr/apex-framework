---
name: learn
description: Project-specific lesson distiller. Reads baseline-pinned git diff, appends novel patterns to .claude-tmp/lessons-tmp.md.
model: sonnet
---

# learn

Spec: `skills/apex/steps/11-tail.md`.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit the parent session's user-global rules - load them explicitly before any action).

## Input

`git diff {diff_anchor}` where `diff_anchor` is passed verbatim in the spawn prompt by the caller. /apex orchestrator resolves it as `git merge-base <manifest.base_branch> HEAD` (the apex/<session> branch's fork point - stable across the session lifecycle since the worktree branched off at session mint). apex-fix orchestrator passes the pre-fix HEAD sha captured at Step 0. Either way the diff stays valid through step 12's commit.

## Output

Append novel patterns under `flock`. Resolve the target to the MAIN worktree (not the linked apex worktree this agent runs in) so `cleanup-session.sh`'s `git worktree remove --force` does not wipe the file before `/apex-lessons` extract consumes it:

```
MAIN=$(git rev-parse --git-common-dir 2>/dev/null | sed 's,/\.git$,,')
[[ -z "$MAIN" || "$MAIN" == ".git" ]] && MAIN=$(pwd)
bash skills/apex/scripts/append-with-lock.sh "$MAIN/.claude-tmp/lessons-tmp.md"
```

In the main worktree `git rev-parse --git-common-dir` returns `.git` (fallback to `pwd`); in a linked worktree it returns the absolute path to the main repo's `.git`. Either way the file lives on the main worktree and survives session cleanup.

Curation into the project lessons-index is owned by `/apex-lessons`.

## What counts as a pattern

The bar is **evidence of difficulty** in this session. A lesson is worth recording ONLY if all three hold:

1. **Difficulty signal in the trace.** `.claude-tmp/apex-active/{session}-fix-attempts.json` shows `attempts >= 1` (verify fix-loop ran), OR the spawn prompt explicitly tags this run as multi-retry / non-converging. First-try-clean sessions do NOT produce lessons - skip the agent's body and exit silently. **Stale-lesson exception:** if the diff or spawn prompt notes that an existing lesson is now contradicted / superseded by this session's fix, append a one-line `stale-lesson:` entry (lesson id + why stale) to `~/.claude/tmp/apex-workflow-improvements.md` via `append-with-lock.sh` BEFORE the silent exit - the difficulty gate must not swallow the only correction signal for stale lesson prose.
2. **Concrete cause.** The diff carries the surprise that caused the retry: a hidden constraint, a race / ordering rule, a framework gotcha, an anti-default behavior. State the cause and the fix together; both are required.
3. **Non-derivable.** The pattern is NOT inferable from `CLAUDE.md` or framework docs.

NOT patterns (drop, even if interesting): trivial bug fixes, env-var defaults, table / column descriptions, route catalog, "I learned the API" facts, generic best-practice restatements, one-off cleanups, observations that did not require a retry.

**Default = drop.** A normal-difficulty session SHOULD append zero lessons. One lesson per ~5-10 sessions is the calibration target. If you find yourself writing more than one entry, you are catching trivia - re-read criterion 1.

`reflector` (step 13) is the apex-workflow counterpart; this agent stays project-scoped.

## Tiers

`economy`: SKIPPED. `standard`: parallel with `documentation.md`.