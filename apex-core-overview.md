# /apex - Skeleton

What runs, when, on what model. Full spec: `apex-core.md`; runtime contract: `skills/apex/SKILL.md`.

Legend: `inline` = main-orchestrator inline work | `agent` = `~/.claude/agents/*.md` | `script` = `~/.claude/skills/apex/scripts/*` | `hook` = wired in `settings.json`.

---

## Lanes (picked once at session start)

| Lane     | Executor model | Shape                                                                                   |
| -------- | -------------- | ---------------------------------------------------------------------------------------- |
| trivial  | none (inline)  | one obvious edit to a named file, no new public symbol, no cross-file ripple; edit inline, commit, done |
| standard | Sonnet         | bounded, mechanical, multi-file; delegate to `agents/executor.md`                        |
| complex  | Sonnet         | judgment / architecture / cross-cutting; decompose hard into minimal-diff tasks + reviewer pass; escalate a SINGLE slice to Opus only when that edit needs reasoning |

The lane decision is made once and never re-litigated per file. Opus is a per-slice exception, never a lane default.

---

## Session flow

```
1. Setup: bash ~/.claude/skills/apex/scripts/mint-worktree.sh   (from the project root)
   - mints {session} (8-hex), worktree <main>/.apex-worktrees/<session>/ on branch apex/<session>,
     symlinks dep caches + .env* from main, runs docs/apex-bootstrap.sh if present,
     writes minimal manifest {session, branch, base_branch, worktree_path}
   - exit 1 (non-git cwd / ~/.claude cwd / secondary worktree / detached HEAD) -> abort cleanly
   - then: cd .apex-worktrees/<session> as a top-level Bash call + confirm pwd
     (this arms the worktree fence - the script's internal cd cannot move the session)

2. Route once: trivial | standard | complex (see Lanes)

3. Drive (orchestrator judgment; a typical shape, not a mandated order):
   - understand/reuse: Grep/Read existing code; Explore agent only when the surface is wide
   - implement: smallest single-purpose tasks -> agents/executor.md briefs that NAME exact
     target files, demand a minimal diff, and pass the absolute worktree_path (cd + pwd first);
     parallel via run_in_background when file sets are disjoint; reconcile returns against
     git status --porcelain; partial -> redispatch smaller
   - verify: targeted per-package typecheck/test/lint by default; escalate to
     verify-build.sh --session <session> --with-tests for cross-cutting ripple;
     non-zero -> executor fix-loop (Sonnet, cap 3), then surface
   - polish/review (complex lane): executor cleanup pass + executor report-only review
     against CLAUDE.md rules
   - docs: executor doc task ONLY when behavior/contracts/signatures changed
   - commit: per verified slice on apex/<session>; never batch to one end-commit
   - learn: executor appends a one-line lesson to .claude-tmp/lessons-tmp.md when the
     change taught something reusable (apex-lessons curates later)

4. Hand off: tell the user to run /apex-merge (folds apex/<session> onto its base branch,
   replays logged side-effects, removes the worktree). /apex never merges or pushes itself.
```

---

## Rails (hooks; fire regardless of orchestrator choices)

| Rail              | Hook script (skills/apex/scripts/)  | Gate                                                                 |
| ----------------- | ----------------------------------- | -------------------------------------------------------------------- |
| worktree fence    | `worktree-fence-hook.sh`            | PreToolUse Edit/Write/MultiEdit/NotebookEdit; active only when cwd ($PWD, else event `cwd`) is inside `.apex-worktrees/*`; denies absolute targets outside the session worktree (scratch `~/.claude/tmp` + `/tmp` + `/private/tmp` + `/var/folders` allowed) |
| file-health       | `file-health-hook.sh`               | blocks Edit/Write on files > 400 LOC gaining > 10 net lines; word budgets per `content-budget.json` |
| protect-env       | `protect-env-hook.sh`               | `.env*` never read, written, or Grep-targeted                         |
| block-destructive | `block-destructive-hook.sh`         | no dangerous recursive `rm`, no history rewrites/force pushes, no `git stash` in any form, no worktree self-teardown from inside a session |

Session cleanup: `session-end-hook.sh` (SessionEnd) reaps crash-orphaned worktrees and stale artifacts; committed or dirty worktrees are always preserved for `/apex-merge`, and pid-less manifests are reaped only past a 24h age gate (a live session's just-minted clean worktree is safe). `cleanup-session.sh` holds the keep/remove decision; `sweep-orphan-artifacts.sh` age-gates stray `{session}-*` siblings.

---

## Agents

| Agent                  | Model  | Role                                                                                     |
| ---------------------- | ------ | ----------------------------------------------------------------------------------------- |
| `agents/executor.md`   | Sonnet (Opus per-slice) | the single do-er: implement / polish / docs / lesson tasks, and report-only review; anchors to the worktree first; minimal diff; returns `{status, notes, files_touched}` |
| `Explore` (built-in)   | -      | wide read-only codebase sweeps during understand                                          |

Subagents do NOT inherit working memory or cwd - every input (task, files, mode, session, worktree_path) arrives in the spawn prompt.
