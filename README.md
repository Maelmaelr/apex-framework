# APEX Framework

> APEX turns feature requests into clean, integrated code, and leaves the codebase better than it found it. Every session stays in scope, verifies its own work, and learns from what went wrong - so the next one reaches further with less effort. APEX is allowed to grow new skills, but every skill file must stay lean: nothing new gets added inside unless something else earns its place. Today it ships features solo or via delegated executors. The goal is whole modules - you're the CEO with the vision, APEX is the CTO that ships it.

An opinionated operating system for Claude Code. APEX keeps the speed of ad-hoc "just go fix it" prompting while adding the three things it lacks: model routing, bounded-context delegation, and deterministic guardrails.

---

## Why

Out of the box an LLM assistant is fast but forgetful, confident but shallow, and drifts off scope the moment work gets delegated. Long sessions lose state. Subagents silently edit files nobody asked about. Docs go stale. Audits rely on "I already checked that." Destructive commands and secret files are one typo away. Hard-won lessons evaporate the moment the session ends. APEX exists to remove those failure modes.

---

## How

The main coding workflow enters through `/apex <prompt>`. One entry point; a fenced-dynamic orchestrator. There is no fixed step sequence - the orchestrator sequences the work itself, the way a senior engineer would, inside hard rails enforced by hooks.

### Session shape

1. **Setup.** `skills/apex/scripts/mint-worktree.sh` mints a throwaway git worktree `.apex-worktrees/<session>/` on branch `apex/<session>`, symlinks dep caches, and writes a session manifest. The orchestrator `cd`s in; that arms the fence.
2. **Route once.** One lane decision per session - trivial, standard, or complex - sets the executor model and whether to decompose hard and add a review pass. Never re-litigated per file.
3. **Drive.** Understand and reuse existing code, decompose into smallest single-purpose tasks, dispatch `agents/executor.md` subagents (parallel when file sets are disjoint), reconcile their reports against `git status --porcelain`.
4. **Verify.** Targeted typecheck/test/lint by default; `skills/apex/scripts/verify-build.sh` for cross-cutting ripple. Failures feed an executor fix-loop (cap 3). A clean exit gates completion.
5. **Commit per verified slice** on `apex/<session>`, then hand off: `/apex-merge` folds the branch back onto its base and removes the worktree. `/apex` never merges or pushes itself.

### Lanes

| Lane     | Executor model | Shape                                                                             |
|----------|----------------|------------------------------------------------------------------------------------|
| trivial  | none (inline)  | one obvious edit to a named file; edit inline, commit, done                        |
| standard | Sonnet         | bounded, mechanical, multi-file; delegate to `agents/executor.md`                  |
| complex  | Sonnet         | judgment / cross-cutting; hard decomposition + reviewer pass; Opus per-slice only  |

Every executor runs in its own fresh context inside the session worktree. Edits outside the worktree are blocked at the tool call by the worktree fence hook (`worktree-fence-hook.sh`), not caught in review.

---

## The Pillars

Ten load-bearing ideas. Everything else in the repo is there to implement them.

1. **Dynamic orchestration, hard rails.** No fixed step march, no read-gates. The orchestrator sequences the work; hooks enforce the boundaries. Judgment where it helps, determinism where it matters.
2. **The worktree is the scope.** Every session runs in a throwaway git worktree on its own branch. No file-level allow-lists to compute or maintain - the blast radius is one disposable branch, and the fence hook blocks writes outside it at the tool call.
3. **Think / do split.** The orchestrator reasons, plans, routes, and verifies at low token volume; bounded `executor.md` subagents on the cheap model do the high-volume reading and editing. That split is the cost win.
4. **Route once.** One lane decision per session sizes the effort. One-liners stay one-liners; cross-cutting work gets hard decomposition and a review pass. Opus is a per-slice exception, never a lane default.
5. **Reuse before writing.** Grep and read the existing code, find the pattern, match it exactly. Nothing gets invented that the codebase already has.
6. **Verify, do not trust.** Lint and build gate completion. Failures feed `executor.md` a bounded fix-loop (cap 3). Executor reports are reconciled against `git status --porcelain` - the filesystem, not the promises.
7. **Guardrails as hooks, not habits.** `protect-env-hook.sh` (no `.env*` reads or writes), `block-destructive-hook.sh` (no `rm -rf`, no history rewrites), and the worktree fence fire regardless of what the model decides.
8. **Commit per verified slice.** Each independently-verified slice lands as its own commit on `apex/<session>`. Committed clean work can never be stranded or re-clobbered by a later runaway; `/apex-merge` folds the whole branch.
9. **Lessons as persistent memory.** Sessions append what they learned; `apex-lessons` curates the index. The next run starts with what the last run discovered.
10. **Self-improving, safe, lean, resilient.** Reflection signals and the tech-watch feed accumulate in a log; `apex-improve` consumes them to evolve the framework itself. Skill files stay lean by rule: the file-health hook splits any file that crosses the threshold; nothing new gets added unless something else earns its place.

---

## What You Get

- **Effort matches the task.** Trivial edits skip the ceremony. Cross-cutting changes get hard decomposition, delegated executors, and a review pass.
- **No surprise edits.** Every session runs inside a dedicated git worktree minted by `mint-worktree.sh`; the worktree fence hook blocks writes outside it at the tool call.
- **No lost work.** A runaway executor can only trash one throwaway branch; every verified slice is already committed behind it.
- **Shorter, cheaper sessions.** The orchestrator thinks; Sonnet executors in fresh bounded contexts do the bulk. The main session stays small.
- **Done means tested.** Every implementation run ends with build, lint, and a bounded fix-loop. Failures block completion.
- **Code and docs stay healthy.** The file-health hook splits files before they hit the complexity cliff. Doc updates ship in the same session when behavior, contracts, or signatures changed.
- **Cumulative learning.** `learn.md` distills lessons; `apex-lessons` curates them; `apex-improve` evolves the framework itself from accumulated reflection signals.
- **Trustworthy autonomy.** Fail-closed guardrails mean APEX can run without supervision and still stay on rails.
- **A framework that evolves with you.** The reflector log + tech-watch fetcher feed `apex-improve`, which proposes edits to the framework on a weekly cadence.

---

## Skills

- **apex/** - Main coding orchestrator, fenced-dynamic (entry: `apex/SKILL.md`; `scripts/` holds the worktree fence, guard hooks, and verify scripts).
- **apex-init/** - Initialize a new project with apex-compatible structure (`.claude-tmp`, docs, `CLAUDE.md`).
- **apex-fix/** - Standalone lint/build fix loop. Mints a synthetic session, runs `verify-build.sh`, spawns `executor.md` capped at 3 attempts.
- **apex-merge/** - Integrate `apex/<session>` worktree branches back into their recorded base branches; replays logged side-effects; removes worktrees. Manual trigger; runs from the main worktree.
- **apex-lessons/** - Curate lessons. Two phases: extract (consolidate pending) + analyze (triage / dedupe / route).
- **apex-improve/** - Self-improvement engine. Consumes reflector log + tech-watch updates + Claude Code version stamp. Slash-invokable.
- **apex-tech-watch/** - Weekly tech-watch fetcher. Reads `sources.json`, summarizes via WebFetch / WebSearch, appends to `tech-updates.md`. Cron-driven (Sunday 06:00 local). Output consumed by `apex-improve`.
- **admin-apex/** - Framework maintainer. Audit / evolve / sync-docs / test / commit / mirror-to-public / push / self-reflect chain. Maintainer-only.

## Agents

- **executor.md** - The single `/apex` do-er: implement / polish / docs / lesson tasks, plus report-only review. Anchors to the session worktree first; minimal diff; returns structured status.
- **learn.md** - Project-specific lesson distiller (spawned by `/apex-fix` after multi-retry fixes).
- **reflector.md** - Self-reflection at admin-apex, apex-lessons, apex-merge, apex-tech-watch reflection points. Sonnet, foreground, silent.
- **apex-merge-resolver.md** - Per-conflicted-file resolver spawned by `/apex-merge`. Reports a proposed resolution; never edits.

---

## Installation

APEX is a set of Claude Code skills, agents, and hooks that live in your Claude Code config directory (`~/.claude`). Every skill, agent, and hook in the framework resolves its paths against `~/.claude`, so install it there (a single global install shared by all your projects):

```bash
git clone https://github.com/Maelmaelr/apex-framework.git
cd apex-framework

mkdir -p ~/.claude/skills ~/.claude/agents
cp -R skills/* ~/.claude/skills/
cp -R agents/* ~/.claude/agents/
cp apex-core.md apex-core-overview.md VERSION ~/.claude/
```

The hooks that enforce the worktree fence, file-health splitting, `.env` protection, destructive-command blocking, and session-end cleanup are defined in `settings.json`. If you do not already have a `~/.claude/settings.json`, copy it directly; otherwise merge its `hooks` and `permissions` blocks into your existing file (do not blindly overwrite - your file also carries your own permissions and preferences):

```bash
cp settings.json ~/.claude/settings.json        # only if you have none yet
```

Restart Claude Code, then from any project:

```bash
/apex-init                  # scaffold .claude-tmp/, docs/, CLAUDE.md in the current project
/apex "your first task"     # run the main orchestrator
```

---

## Usage

```
/apex-init                  # scaffold APEX structure in a new project
/apex "task description"    # main coding orchestrator (fenced-dynamic, lane auto-decided)
/apex-fix                   # standalone lint/build fix loop
/apex-merge                 # integrate apex/<session> worktree branches into their base
/apex-lessons               # curate the lessons index
```

---

## Naming convention

| Layer | Location | Convention |
|-------|----------|------------|
| Top-level skill (slash command) | `skills/<name>/SKILL.md` | `apex-<verb>` |
| Skill sub-file (internal) | `skills/<skill>/<phase>.md` | `<phase>.md` (e.g. `apex-improve/analyze.md`) |
| Agent | `agents/<role>.md` | `<role>.md` |
| Script | `skills/apex/scripts/` or `skills/admin-apex/scripts/` | `<verb>-<noun>.{sh,py}`; `<purpose>-hook.sh` |
| Schema | `skills/admin-apex/schemas/` | `<artifact>.schema.json`; `$id == basename(path)` |

---

## Versioning

The apex framework follows semver in `VERSION`. `admin-apex` task 9 bumps on its own commits per the bump rule:

- patch: only `edit` ops applied
- minor: any additive op (`create` / `schema-add` / `hook-add`)
- major: any restructuring/removal op (`rename` / `split` / `merge` / `retire` / `schema-remove` / `hook-remove`)

---

## Documentation

Authoritative sources (in load order):

1. `apex-core.md` - full `/apex` behavioral contract (fenced-dynamic rails: worktree fence, verify gate, executor dispatch, apex-merge handoff)
2. `apex-core-overview.md` - skeleton/skim view of the same contract
3. `skills/admin-apex/SKILL.md` - framework maintainer reference (audit, evolve, sync-docs, mirror, version, push, self-reflect)
