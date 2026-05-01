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
| 5 | this skill | Cleanup + version stamp (inline) |
| 6 | this skill | Structured report (inline) |
| 7-8 | `sync-git.md` | VERSION + commit + mirror + push (standalone-mode only; mirrors admin-apex tasks 9+10) |

## Step 0: TaskCreate the chain

```
1. Mint run + manifest          - inline
2. Analyze signals              - analyze.md (early-exit on no signals)
3. Plan ops                     - plan.md
4. Apply ops                    - apply.md
5. Cleanup + stamp              - inline
6. Report                       - inline
7. VERSION + commit             - sync-git.md (standalone only)
8. Mirror + push both           - sync-git.md (standalone only)
```

Each task `blockedBy` the previous. Steps 3-6 conditional on Step 2 non-empty findings; Steps 7-8 conditional on standalone mode AND >=1 op applied.

## Step 1: Mint run + manifest (inline)

```
RUN=$(openssl rand -hex 4)
ROOT=".claude-tmp/admin-apex-active"
mkdir -p "$ROOT"
CC_ID=$(bash skills/apex/scripts/get-cc-session-id.sh)   # env-then-jsonl resolver; abort on failure
PID=$PPID                                                 # parent claude PID (NOT $$)
```

**Write** `$ROOT/$RUN.json` with `{"run":"<RUN>","cc_session_id":"<CC_ID>","pid":<PID>,"producer":"apex-improve"}`. NEVER write `cc_session_id:""` - empty makes `session-end-hook.sh` unable to match the manifest, leaking the run. `cc_session_id` arms `skills/admin-apex/scripts/session-end-hook.sh` to sweep at CC SessionEnd (covers no-signals exit, cap-reached abort, standalone-without-commit); `pid` arms `skills/admin-apex/scripts/sweep-stale-runs.sh` to drain orphans from crashed sessions. `{run}-deferred-findings.json` is preserved by `cleanup-run.sh` for a future run.

## Step 2: Analyze signals

Read and follow `~/.claude/skills/apex-improve/analyze.md`. Produces `{run}-findings.json`.

If empty (zero findings across all three sources), exit cleanly with `apex-improve: no signals to consume`; skip Steps 3-6 (manifest swept by SessionEnd hook; do NOT truncate any input file).

## Step 3: Plan ops

Read and follow `~/.claude/skills/apex-improve/plan.md`. Produces `{run}-evolve-plan.json` (same schema as admin-apex evolve task 5; lets Step 4 hand off without translation).

## Step 4: Apply ops

Read and follow `~/.claude/skills/apex-improve/apply.md`. Produces `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.

If 0 ops applied (every Edit failed and every structural op hit drift), exit with `apex-improve: 0 ops applied; signals preserved for next run`; skip Steps 5-6. Do NOT truncate `apex-workflow-improvements.md` - nothing was consumed.

## Step 5: Cleanup + version stamp (inline)

```
# 5a. Archive consumed signals (next session reflect-traces.sh appends fresh blocks)
ARCHIVE_DIR="$HOME/.claude/tmp/improvements-archive"; mkdir -p "$ARCHIVE_DIR"
DATE=$(date -u +%Y-%m-%dT%H-%M-%SZ)
TARGET="$HOME/.claude/tmp/apex-workflow-improvements.md"
[[ -s "$TARGET" ]] && { cp "$TARGET" "$ARCHIVE_DIR/${DATE}-workflow-improvements.md"; : > "$TARGET"; }

# 5b. Stamp CC version (closes version-drift signal until next CC update)
claude --version | awk '{print $1}' > "$HOME/.claude/tmp/apex-claude-code-version.txt"
```

`tech-updates.md` is NOT truncated - apex-tech-watch's 30-day rotation owns its lifecycle. The CC-version stamp lives under `~/.claude/tmp/` (gitignored); local-state only, not committed. Add to `{run}-dirty-paths.txt` only if content changed (`git diff --quiet` check).

## Step 6: Report (inline)

Print a structured summary to stdout (apex-eod step 3 captures and prints this verbatim):

```
apex-improve run {run} complete.

Findings consumed: <N> (workflow-improvements: <a>, tech-updates: <b>, version-drift: <c>)
Operations applied: <N>
  - semantic: <n>
  - replace:  <n>
  - structural: <n> (split: x, rename: y, retire: z, create: w)

Per-file delta_lines (top 5 by absolute value):
  +<n>  <path>
  -<n>  <path>
  ...

Net delta_lines across run: <signed int>
```

If `Net delta_lines > +50` OR `additive` ops > 1, append a Principle 3 note: `this run grew the framework by N lines / created M new files; review whether the findings could have been satisfied semantically`. Informational only - the run still commits.

## Steps 7-8: VERSION + commit + mirror + push

Read and follow `~/.claude/skills/apex-improve/sync-git.md`. Standalone-mode only (skipped under apex-eod and when Step 4 applied zero ops); reuses admin-apex's `admin-apex-finalize.sh` + `mirror-to-dev.sh`.

## Subagent invocation contract

When `apex-eod` step 3 runs apex-improve as a subagent, the prompt template is:

```
ASCII only. No tables, no diagrams. Read and follow all instructions in
~/.claude/skills/apex-improve/SKILL.md. Execute every step. You are running
as a subagent under apex-eod - do NOT commit or push (apex-eod step 5
owns the inline commit). Report the Step 6 summary verbatim.
```

The "do NOT commit or push" line is the explicit signal that suppresses Steps 7+8. apex-eod step 5 remains the only commit driver in EOD context; standalone `/apex-improve` runs execute Steps 7+8 (mirrors admin-apex tasks 9+10).

## What this skill does NOT do

- Does NOT scout, plan teammates, or run /apex's verify-fix loop - this is an out-of-band meta-task on the apex framework itself, not on user code.
- Does NOT touch project app code, run project lint/build, or modify `.env*`.
- Does NOT commit or push under apex-eod (Steps 7-8 skipped via subagent-prompt directive); standalone runs DO commit + mirror + push at session end (mirrors admin-apex tasks 9+10).
- Does NOT bypass the file-health hook - if a Step 4 semantic edit would push a file past 400 lines, the hook fires and apex-improve must AskUserQuestion (`split-now | reduce-edit | abort`). Same gate any apex skill respects.
- Does NOT decide that a tech-update is irrelevant on its own - if uncertain whether to apply a tech-watch finding, defer it (write to `{run}-deferred-findings.json`) rather than guess.

See `analyze.md`, `plan.md`, `apply.md` for per-step contracts; `~/.claude/skills/admin-apex/evolve.md` for the structural-ops engine; `~/.claude/skills/admin-apex/scripts/admin-apex-finalize.sh` + `mirror-to-dev.sh` for the shared commit + mirror drivers; `~/.claude/skills/apex/shared-guardrails.md` for safety paths and JSON-Schema validation; `~/.claude/skills/apex-tech-watch/SKILL.md` for the upstream tech-updates fetcher.
