---
name: apex-improve
description: Self-improvement engine for the apex framework. Consumes ~/.claude/tmp/apex-workflow-improvements.md (per-session reflector + heuristic signals), ~/.claude/tmp/tech-updates.md (weekly tech-watch fetch), and the apex-claude-code-version.txt stamp. Applies semantic Edit first, escalates to admin-apex/evolve.md only when a structural change is the only honest fit. Slash-invokable; called by apex-eod step 3.
triggers:
  - apex-improve
---

# /apex-improve

Self-improvement engine. Reads accumulated session-reflection signals + weekly tech-watch updates, proposes edits to the apex framework, applies semantic adjustments inline (preferred), delegates structural mutations to `~/.claude/skills/admin-apex/evolve.md`. Out-of-band - not part of /apex hot path; no project app code, no project lint/build.

Shares `.claude-tmp/admin-apex-active/` with admin-apex (8-hex token collisions negligible); Step 4 structural ops produce the same `{run}-applied-ops.json` + `{run}-dirty-paths.txt` shape admin-apex expects. **Standalone runs sync git at session end** (Steps 7+8: VERSION bump + commit + mirror to public repo + push both, mirroring admin-apex tasks 9+10). **Subagent runs under apex-eod skip Steps 7+8** (apex-eod step 5 owns the inline commit; the subagent prompt explicitly instructs the skill to skip).

## Guiding principle (Principle 3)

> Focus first on semantic adjustments - it's usually enough. Only add new lines if necessary. If a skill / subskill / agent / script / hook grows too much, you're not on the right track. Adding more and more just becomes more confusing and bloats agent context.

Edit hierarchy (smallest-first):

1. **Semantic** - rephrase, tighten, clarify, fix wrong wording. Same line count or fewer.
2. **Replace** - swap an outdated approach for the current best practice. Net delta near zero.
3. **Extract** - a file is too large; split a separable concern out (lines move, total grows minimally).
4. **Additive** - net new lines for genuinely new capability. Only when 1-3 cannot express the improvement.

Track per-file `delta_lines` through Step 4 and surface in Step 6. Growth is **advisory, not blocking**; visible accretion lets future runs correct it. Reaching for "additive" twice in one run is a signal the finding belongs in a *different* file.

## Inputs

| File | Source | Empty / missing -> |
|------|--------|---------------------|
| `~/.claude/tmp/apex-workflow-improvements.md` | reflect-traces.sh + agents/reflector.md (per session) | nothing to consume from session-reflection track |
| `~/.claude/tmp/tech-updates.md` | apex-tech-watch (weekly cron / launchd) | **missing** or **mtime > 14 days** -> Step 2 emits a `tech-watch never-run / stale` finding with `target_files: []` (Principle 2: weekly currency silently broken otherwise). Both surface in Step 6 report only. See `analyze.md` for finding shape. Otherwise: nothing to consume. |
| `~/.claude/tmp/apex-claude-code-version.txt` | apex-improve writes on completion | missing -> CC version drift since last run; treat as a soft signal that current best practices may have shifted |

If all three signals empty / current at Step 2 -> exit `apex-improve: no signals to consume`; skip Steps 3-6.

## Step ownership

| Step | Owner | Notes |
|------|-------|-------|
| 0 | this skill | TaskCreate the chain |
| 1 | this skill | Mint run + manifest (inline) |
| 2 | `analyze.md` | Phase 1: signal extraction; produces `{run}-findings.json` |
| 3 | `plan.md` | Phase 2: planning + schema validation; produces `{run}-evolve-plan.json` |
| 4 | `apply.md` | Phase 3: apply ops (3a semantic Edit, 3b delegate to admin-apex/evolve.md) |
| 5-6 | `finalize.md` | Cleanup + version stamp + structured report |
| 7-8 | `sync-git.md` | VERSION + commit + mirror + push (standalone-mode only; mirrors admin-apex tasks 9+10) |
| 9 | this skill | Lessons sweep: spawn `/apex-lessons` if `.claude/lessons.md` exists (standalone-mode only) |

## Step 0: TaskCreate the chain

```
1. Mint run + manifest          - inline
2. Analyze signals              - analyze.md (early-exit on no signals)
3. Plan ops                     - plan.md
4. Apply ops                    - apply.md
5-6. Cleanup + stamp + Report   - finalize.md
7. VERSION + commit             - sync-git.md (standalone only)
8. Mirror + push both           - sync-git.md (standalone only)
9. Lessons sweep                - inline (standalone only; pre-flight `.claude/lessons.md` exists)
```

Each task `blockedBy` the previous. Steps 3-6 conditional on Step 2 non-empty findings; Steps 7-8 conditional on standalone mode AND >=1 op applied; Step 9 conditional on standalone mode AND `.claude/lessons.md` exists.

## Step 1: Mint run + manifest (inline)

**Cwd discipline (critical).** Before any other action, `cd "$HOME/.claude"`. apex-improve operates on the apex framework at `~/.claude` and writes artifacts under `~/.claude/.claude-tmp/admin-apex-active/`; running from a project repo would pollute that project's working tree and the SessionEnd hook for an unrelated cwd would never match this run's manifest (cleanup leak). Absolute paths below provide defense-in-depth.

```
cd "$HOME/.claude"
RUN=$(openssl rand -hex 4)
ROOT="$HOME/.claude/.claude-tmp/admin-apex-active"
mkdir -p "$ROOT"
CC_ID=$(bash "$HOME/.claude/skills/apex/scripts/get-cc-session-id.sh")   # env-then-jsonl resolver; abort on failure
PID=$PPID                                                                # parent claude PID (NOT $$)
```

**Write** `$ROOT/$RUN.json` with `{"run":"<RUN>","cc_session_id":"<CC_ID>","pid":<PID>,"producer":"apex-improve"}`. NEVER write `cc_session_id:""` - empty makes `session-end-hook.sh` unable to match the manifest, leaking the run. `cc_session_id` arms `skills/admin-apex/scripts/session-end-hook.sh` to sweep at CC SessionEnd (covers no-signals exit, cap-reached abort, standalone-without-commit); `pid` arms `skills/admin-apex/scripts/sweep-stale-runs.sh` to drain orphans from crashed sessions. `{run}-deferred-findings.json` is preserved by `cleanup-run.sh` for a future run.

## Step 2: Analyze signals

Read and follow `~/.claude/skills/apex-improve/analyze.md`. Produces `{run}-findings.json`.

If empty (zero findings across all three sources), skip Steps 3-4 but still run Step 5 (archive + truncate consumed signal files + CC version stamp) so `apex-workflow-improvements.md` and `tech-updates.md` reset for the next session - leaving stale signal blocks in place re-feeds them as deja-vu noise on the next run, even though no ops were emitted. Print a minimal Step 6 line `apex-improve: no signals to consume` (no findings/ops table). Skip Steps 7-8 (no diff to commit). Manifest swept by SessionEnd hook.

## Step 3: Plan ops

Read and follow `~/.claude/skills/apex-improve/plan.md`. Produces `{run}-evolve-plan.json` (same schema as admin-apex evolve task 5; lets Step 4 hand off without translation).

## Step 4: Apply ops

Read and follow `~/.claude/skills/apex-improve/apply.md`. Produces `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.

If 0 ops applied (every Edit failed and every structural op hit drift), still run Steps 5-6 (archive + truncate + stamp + minimal report). The signals were *seen* by analyze.md / plan.md - the failure is in apply, not in the signal track - so the consumed inputs reset normally; deferred findings remain in `{run}-deferred-findings.json` (preserved across SessionEnd by `cleanup-run.sh`) for the next run. Skip Steps 7-8 (no diff to commit).

## Steps 5-6: Cleanup + stamp + Report

Read and follow `~/.claude/skills/apex-improve/finalize.md`. Returns when the structured Step 6 summary has been printed; resume at Steps 7-8 below (standalone mode only).

## Steps 7-8: VERSION + commit + mirror + push

Read and follow `~/.claude/skills/apex-improve/sync-git.md`. Standalone-mode only (skipped under apex-eod and when Step 4 applied zero ops); reuses admin-apex's `admin-apex-finalize.sh` + `mirror-to-dev.sh`.

## Step 9: Lessons sweep (standalone only)

Standalone-mode only (skipped under apex-eod; apex-eod step 2 owns this). Pre-flight: only fire if `test -f .claude/lessons.md` (the project may not have lessons captured yet).

After Steps 7-8 commit + mirror succeed, spawn `/apex-lessons` as a subagent so its determinism / non-determinism mix runs in a fresh context (separate from this run's Step 4 apply context). The orchestrator runs both extract and analyze phases sequentially:

```
Spawn subagent (general-purpose, sonnet, bypassPermissions):
  description: "Run apex-lessons post-improve"
  prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions
           in ~/.claude/skills/apex-lessons/SKILL.md. Execute Step 1 (extract
           phase) then Step 2 (analyze phase). You are running as a subagent
           under apex-improve standalone mode - use deferred routing per the
           analyze phase Route + Finalize subagent restriction. Report the
           extract Step 6 summary line then the analyze Step 9 final summary."
```

Skip silently if pre-flight fails (no lessons.md) or subagent mode is active. Errors from /apex-lessons do NOT block the apex-improve report - it has already committed and mirrored.

This step closes the loop: apex-improve consumes reflector signals (including those produced by the apex-lessons phases' own Reflect + Cleanup) on its NEXT run, and apex-lessons keeps `.claude/lessons.md` lean on every standalone /apex-improve invocation.

## Subagent invocation contract

When `apex-eod` step 3 runs apex-improve as a subagent, the prompt template is:

```
ASCII only. No tables, no diagrams. Read and follow all instructions in
~/.claude/skills/apex-improve/SKILL.md. Execute every step. You are running
as a subagent under apex-eod - do NOT commit or push (apex-eod step 5
owns the inline commit). Report the Step 6 summary verbatim.
```

The "do NOT commit or push" line is the explicit signal that suppresses Steps 7+8 AND Step 9 (apex-eod step 4 owns lessons-analyze separately). apex-eod step 5 remains the only commit driver in EOD context; standalone `/apex-improve` runs execute Steps 7+8 (mirrors admin-apex tasks 9+10) and Step 9 (lessons sweep).

## What this skill does NOT do

- Does NOT scout, plan teammates, or run /apex's verify-fix loop - this is an out-of-band meta-task on the apex framework itself, not on user code.
- Does NOT touch project app code, run project lint/build, or modify `.env*`.
- Does NOT commit or push under apex-eod (Steps 7-8 skipped via subagent-prompt directive); standalone runs DO commit + mirror + push at session end (mirrors admin-apex tasks 9+10).
- Does NOT bypass the file-health hook - if a Step 4 semantic edit would push a file past 400 lines, the hook fires and apex-improve must AskUserQuestion (`split-now | reduce-edit | abort`). Same gate any apex skill respects.
- Does NOT decide that a tech-update is irrelevant on its own - if uncertain whether to apply a tech-watch finding, defer it (write to `{run}-deferred-findings.json`) rather than guess.

See `analyze.md`, `plan.md`, `apply.md`, `finalize.md` for per-step contracts; `~/.claude/skills/admin-apex/evolve.md` for the structural-ops engine; `~/.claude/skills/admin-apex/scripts/admin-apex-finalize.sh` + `mirror-to-dev.sh` for the shared commit + mirror drivers; `~/.claude/skills/apex/shared-guardrails.md` for safety paths and JSON-Schema validation; `~/.claude/skills/apex-tech-watch/SKILL.md` for the upstream tech-updates fetcher.
