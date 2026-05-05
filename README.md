# APEX Framework

> APEX turns feature requests into clean, integrated code, and leaves the codebase better than it found it. Every session stays in scope, verifies its own work, and learns from what went wrong - so the next one reaches further with less effort. APEX is allowed to grow new skills, but every skill file must stay lean: nothing new gets added inside unless something else earns its place. Today it ships features solo or via delegated executors. The goal is whole modules - you're the CEO with the vision, APEX is the CTO that ships it.

An opinionated operating system for Claude Code. APEX replaces ad-hoc "just go fix it" prompting with a deliberate, self-improving pipeline: hypothesize, discover, plan, execute, verify, learn.

This is the public mirror of the apex framework. Source lives in the maintainer's private `~/.claude` and is mirrored here by `admin-apex` on every framework commit.

---

## Why

Out of the box an LLM assistant is fast but forgetful, confident but shallow, and drifts off scope the moment work gets delegated. Long sessions lose state. Subagents silently edit files nobody asked about. Discovery hallucinates findings that look plausible but cite wrong line ranges. Docs go stale. Audits rely on "I already checked that." Destructive commands and secret files are one typo away. Hard-won lessons evaporate the moment the session ends. APEX exists to remove those failure modes.

---

## How

The main coding workflow enters through `/apex <prompt>`. One entry point, one linear 15-step flow, three execution tiers sized to the work.

### Linear 15-step flow (every run)

Step 0 queues tasks 1-15. The trivial detector at step 3 collapses 4-13 into completed-skipped; the economy gate at step 7 picks Sonnet for executors and trims the tail.

1. Analyze prompt + read project context.
2. Create session manifest (`{session}` token; survives context compaction).
3. Trivial pre-flight (single named file + no cross-file deps -> jump to step 14).
4. Hypothesis (interpretation, complexity hint, alternatives, discovered paths).
5. Load lessons + project docs.
6. Discovery (LSP -> Glob -> Grep -> Screener LLM gate; emits scope JSON with claim provenance).
7. Economy pre-flight (tier classifier).
8. Execute (per-task `executor.md` dispatch; Sonnet under economy, main session model under standard).
9. Polish (in-scope unused-imports / dead-code / leftover comments).
10. Verify (lint + build; bounded fix-loop with `executor.md`, cap 3).
11. Tail (`documentation.md` + `learn.md` in standard; only `documentation.md` in economy).
12. VERSION bump + git stage / commit / push.
13. Self-reflect (`reflector.md`, Haiku, foreground, silent).
14. Cleanup session artifacts.
15. Inline summary.

### Tiers

| Tier     | Decided at | Effect                                                                        |
|----------|------------|-------------------------------------------------------------------------------|
| trivial  | step 3     | Inline single Edit/Write -> jump to 14. Skips 4-13.                           |
| economy  | step 7     | Step 8 executors = Sonnet; step 11 `learn` skipped.                           |
| standard | step 7     | Step 8 executors = main session model; full tail (`documentation` + `learn`). |

Every executor runs in its own fresh 1M-token context with a scoped allowed-files list. Edits outside scope are blocked at the tool call by the scope-check hook, not caught in review.

---

## The Pillars

Ten load-bearing ideas. Everything else in the repo is there to implement them.

1. **Complexity-gated routing.** Trivial detection at step 3 short-circuits the full flow. The economy gate at step 7 picks Sonnet executors when the work fits. Effort matches the task; one-liners stay one-liners.
2. **Hypothesis before discovery, discovery before code.** The hypothesis is written down at step 4 so bias is visible. Discovery confirms or corrects it. Nothing gets edited before the picture is verified.
3. **Deterministic enumeration first, LLMs second.** Step 6 cascades LSP -> Glob -> Grep mechanically. The Screener LLM filters the keep/drop set but never invents file paths. The ground-truth list is never a hallucination.
4. **Pointers, not bodies.** Discovery findings persist on disk as scope JSON; executors and the orchestrator read pointers. The main session never bloats with implementation noise.
5. **Anti-hallucination as a phase.** Every claim - file path, line range, reason - is recorded with provenance and re-readable. Bad claims are dropped mechanically; bad-claim ratios trigger re-runs.
6. **Session state that survives context clearing.** A `{session}` manifest persists across context compaction and API failures. Long runs do not lose state.
7. **Scoped delegation, enforced at the tool call.** Every executor has an allowed-files list. Edits outside it are blocked by the scope-check hook, not caught in review. The file-health hook splits oversized files before writes land.
8. **Verify, do not trust.** Step 10 runs lint and build. Failures block completion and feed `executor.md` a bounded fix-loop (cap 3). "It looked right" is not a verdict.
9. **Lessons and discovery findings as persistent memory.** Every session reads the lessons index first and writes back what it learned. Discovery scope JSON persists per session. Next run starts with what the last run discovered; duplicates merge, stale entries age out.
10. **Self-improving, safe, lean, resilient.** Step 13 reflection appends signals to the improvement log every run; `apex-improve` consumes those signals weekly to evolve the framework. Destructive commands, `.env` reads, and force-pushes to main are blocked outright. Skill files stay lean by rule: `apex-file-health` splits any file that crosses the threshold; nothing new gets added unless something else earns its place.

---

## What You Get

- **Effort matches the task.** Trivial edits skip the ceremony. Cross-cutting changes get discovery, hypothesis, claim verification, and delegated executors.
- **No surprise edits.** Non-trivial work is scoped before any file is touched; the scope-check hook blocks out-of-scope writes at the tool call.
- **Findings you can trust.** Deterministic enumeration plus claim-provenance means "discovery said so" actually means something.
- **Fewer silent failures.** Bad-claim thresholds force re-runs instead of letting hallucinations drive routing.
- **Shorter, cleaner sessions.** Discovery returns pointers, executors run in fresh contexts, the main session stays small.
- **Done means tested.** Every implementation run ends with build, lint, and a bounded fix-loop. Failures block completion.
- **Code and docs stay healthy.** `apex-file-health` splits files before they hit the complexity cliff. `documentation.md` updates project docs alongside the code that changed them.
- **Cumulative learning.** `learn.md` distills lessons every standard-tier run. `apex-lessons` curates them. `apex-improve` evolves the framework itself from accumulated reflection signals.
- **Trustworthy autonomy.** Fail-closed guardrails mean APEX can run without supervision and still stay on rails.
- **A framework that evolves with you.** The reflector log + tech-watch fetcher feed `apex-improve`, which proposes edits to the framework on a weekly cadence.

---

## Skills

- **apex/** - Main coding orchestrator (entry: `apex/SKILL.md`). Sub-skills: `discover.md` (step 6), `execute.md` (step 8).
- **apex-eod/** - End of day. Chains `apex-file-health` -> `apex-lessons` (extract + analyze) -> `apex-improve` -> inline git commit.
- **apex-fix/** - Standalone lint/build fix loop. Mints a synthetic session, runs `verify-build.sh`, spawns `executor.md` capped at 3 attempts.
- **apex-file-health/** - Remediate oversized files flagged by `/apex` verify (step 10). Splits, verifies, runs tail tasks.
- **apex-init/** - Initialize a new project with apex-compatible structure (`.claude-tmp`, docs, `CLAUDE.md`).
- **apex-improve/** - Self-improvement engine. Consumes reflector log + tech-watch updates + Claude Code version stamp. Slash-invokable; called by `apex-eod`.
- **apex-lessons/** - Curate lessons. Two phases: extract (consolidate pending) + analyze (triage / dedupe / route).
- **apex-tech-watch/** - Weekly tech-watch fetcher. Reads `sources.json`, summarizes via WebFetch / WebSearch, appends to `tech-updates.md`. Cron-driven (Sunday 06:00 local). Output consumed by `apex-improve`.
- **admin-apex/** - Framework maintainer. Audit / evolve / sync-docs / test / commit / mirror-to-public / push / self-reflect chain. Maintainer-only.

## Agents

- **executor.md** - Per-task implementation. Step 8 dispatch + step 10 verify fix-loop.
- **screener.md** - Step 6 discovery gate. Filters cascade output (LSP / Glob / Grep) to keep / drop set.
- **documentation.md** - Step 11 tail subagent. Updates project docs / architecture notes when structural changes warrant.
- **learn.md** - Step 11 tail subagent. Project-specific lesson distiller. Skipped under economy tier.
- **reflector.md** - Self-reflection at apex step 13, admin-apex task 11, apex-improve. Haiku, foreground, silent.

---

## Usage

```
/apex "task description"    # main coding orchestrator (15 steps, tier auto-decided)
/apex-fix                   # standalone lint/build fix loop
/apex-eod                   # end-of-day: file-health + lessons + improve + commit
/apex-lessons               # curate lessons index
```

---

## Naming convention

| Layer | Location | Convention |
|-------|----------|------------|
| Top-level skill (slash command) | `skills/<name>/SKILL.md` | `apex-<verb>` |
| Skill sub-file (internal) | `skills/apex/<phase>.md` | `<phase>.md` (e.g. `discover.md`, `execute.md`) |
| Agent | `agents/<role>.md` | `<role>.md` |
| Script | `skills/apex/scripts/` or `skills/admin-apex/scripts/` | `<verb>-<noun>.{sh,py}`; `<purpose>-hook.sh` |
| Schema | `skills/apex/schemas/` or `skills/admin-apex/schemas/` | `<artifact>.schema.json`; `$id == basename(path)` |

---

## Versioning

The apex framework follows semver in `VERSION`. `admin-apex` task 9 bumps on its own commits per the bump rule:

- patch: only `edit` ops applied
- minor: any additive op (`create` / `schema-add` / `hook-add`)
- major: any restructuring/removal op (`rename` / `split` / `merge` / `retire` / `schema-remove` / `hook-remove`)

---

## Documentation

Authoritative sources (in load order):

1. `apex-core.md` - full `/apex` behavioral contract (15 steps, tiers, conventions, failure handling)
2. `apex-core-overview.md` - skeleton/skim view of the same contract
3. `skills/admin-apex/SKILL.md` - framework maintainer reference (audit, evolve, sync-docs, mirror, version, push, self-reflect)
