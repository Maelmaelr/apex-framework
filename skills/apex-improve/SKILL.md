---
name: apex-improve
description: Self-improvement engine for the apex framework. Consumes ~/.claude/tmp/apex-workflow-improvements.md (per-session reflector + heuristic signals), ~/.claude/tmp/tech-updates.md (weekly tech-watch fetch), and the apex-claude-code-version.txt stamp. Applies semantic Edit first, escalates to admin-apex/evolve.md only when a structural change is the only honest fit. Slash-invokable; called by apex-eod step 3.
triggers:
  - apex-improve
---

# apex-improve - Self-Improvement Engine

Reads accumulated session-reflection signals + weekly tech-watch updates, proposes edits to the apex framework, applies semantic adjustments inline (preferred), delegates structural mutations to `admin-apex/evolve.md`. **No push** -- commit owned by `apex-eod` step 5 when run from EOD; standalone runs leave the commit to the user (or admin-apex task 9/10 if invoked under that flow).

## Guiding principle (Principle 3)

> Focus first on semantic adjustments -- it's usually enough. Only add new lines if necessary. If a skill / subskill / agent / script / hook grows too much, you're not on the right track. Adding more and more just becomes more confusing and bloats agent context.

This is **the** edit hierarchy:

1. **Semantic** -- rephrase, tighten, clarify, fix wrong wording. Same line count or fewer.
2. **Replace** -- swap an outdated approach for the current best practice. Net delta near zero.
3. **Extract** -- a file is too large; split a separable concern out (lines move, total grows minimally).
4. **Additive** -- net new lines for genuinely new capability. Only when 1-3 cannot express the improvement.

Track per-file `delta_lines` through Phase 4 and surface it in the Phase 5 commit-message body. Growth is **advisory, not blocking** (per user decision); the report makes accretion visible so future runs can correct it. If you find yourself reaching for "additive" twice in one run, stop and re-examine the findings -- the signal probably belongs in a *different* file.

## Inputs

| File | Source | Empty / missing -> |
|------|--------|---------------------|
| `~/.claude/tmp/apex-workflow-improvements.md` | reflect-traces.sh + agents/reflector.md (per session) | nothing to consume from session-reflection track |
| `~/.claude/tmp/tech-updates.md` | apex-tech-watch (weekly cron / launchd) | **missing** -> emit a Phase 1 finding with `source: tech-updates`, `summary: "tech-watch never run; user has not deployed weekly automation"`, `candidate_op: "semantic"`, `target_files: []` (Principle 2: weekly currency is silently broken otherwise). **mtime > 14 days** -> emit `summary: "tech-watch stale (last run YYYY-MM-DD)"` finding. Both findings carry `target_files: []` so Phase 2 cannot promote them to ops; they surface in Phase 5 report only and prompt the user to invoke `/apex-tech-watch` or set up the launchd/cron per `skills/apex-tech-watch/SKILL.md`. Otherwise: nothing to consume from tech-watch track. |
| `~/.claude/tmp/apex-claude-code-version.txt` | apex-improve writes on completion | missing -> CC version drift since last run; treat as a soft signal that current best practices may have shifted |

If all three signal sources are empty / current, exit with `apex-improve: no signals to consume` and skip phases 2-5.

## Step 0: Mint run token + workspace

```
RUN=$(openssl rand -hex 4)
ROOT=".claude-tmp/admin-apex-active"
mkdir -p "$ROOT"
echo "$RUN" > "/tmp/${RUN}-apex-improve.txt"   # token-prefix so cleanup-run.sh sweeps it
CC_ID=$(bash skills/apex/scripts/get-cc-session-id.sh)   # env-then-jsonl resolver; abort on failure
PID=$PPID                                                 # parent claude PID (NOT $$)
```

Then **Write** `$ROOT/$RUN.json` with `{"run":"<RUN>","cc_session_id":"<CC_ID>","pid":<PID>,"producer":"apex-improve"}`. NEVER write `cc_session_id:""` - an empty value makes `session-end-hook.sh` unable to ever match this manifest, leaking the entire run. The `cc_session_id` arms `skills/admin-apex/scripts/session-end-hook.sh` to sweep this run's artifacts when the CC session ends (covers no-signals exit, cap-reached / no-progress abort, and standalone-without-commit runs); the `pid` arms `skills/admin-apex/scripts/sweep-stale-runs.sh` to drain orphans from prior crashed sessions. `{run}-deferred-findings.json` is preserved across SessionEnd by `cleanup-run.sh` for a future run to pick up.

apex-improve shares `.claude-tmp/admin-apex-active/` with admin-apex (token collisions are statistically negligible at 8-hex). Phase 3 structural ops produce the same `{run}-applied-ops.json` + `{run}-dirty-paths.txt` shape that admin-apex expects, so apex-eod step 5's commit can stage them with the existing logic.

## Step 1: Analyze signals

Read the three input files (any that exist). Build a flat list of **findings**:

```
{
  "id":           "<short slug, e.g. 'reflect-novel-noisy'>",
  "source":       "workflow-improvements" | "tech-updates" | "version-drift",
  "summary":      "<one-line>",
  "evidence":     "<exact quoted lines from input file, max 5>",
  "candidate_op": "semantic" | "replace" | "extract" | "additive",
  "target_files": ["<repo-relative path>", ...],
  "rationale":    "<one-line: why this is the right op-class>"
}
```

### Source-specific extraction

**workflow-improvements.md** -- block-structured. Two block kinds:

- `## {session} - {phase}-heuristics - {ts}` (always present per session). Read `gap_signals` / `fix_attempts` / `verbose_traces` counts. High counts across many sessions = chronic pattern -> finding.
- `## {session} - {phase} - {ts}` (Haiku reflector, present every session post-1.4.0). Read `gaps:` / `fixes-observed:` / `improvements:` lines. Each suggestion is a candidate finding.

Cluster across sessions: if 3+ Haiku blocks suggest the same improvement, finding severity is **high**. Single-session one-off = **low** (often noise).

**tech-updates.md** -- block-structured by source + date. Each block points at a tech-watch URL. Two questions per block:
1. Does this affect any apex file? (grep symbol names from the block against `skills/apex/**`, `agents/**`, `apex-core.md`)
2. If yes, is the apex file already aligned, or out of date?

Drop blocks that have no apex-file hit (informational only -- not every tech update is actionable).

**version-drift** -- if `apex-claude-code-version.txt` is missing or older than the current CC version (`claude --version` parsed), emit one finding: "review CC release notes since version X for behavior changes; check apex hook configurations and skill prompts for affected primitives". This is usually a meta-finding pointing at apex-tech-watch's most recent fetch.

### Output of Phase 1

Write the finding list to `.claude-tmp/admin-apex-active/{run}-findings.json` as a JSON array. **Cap: 12 findings per run.** If more surface, keep the highest-severity 12 and log the rest to `.claude-tmp/admin-apex-active/{run}-deferred-findings.json` for a future run.

## Step 2: Plan

For each finding, pick the **smallest** op-class that satisfies it (per the edit hierarchy). Default bias toward `semantic`. Promotion rules:

- A semantic finding cannot be expressed without breaking sentence flow -> promote to `replace`.
- A replace finding would push the target file past 500 lines -> promote to `extract`.
- An extract finding has no obvious split seam -> escalate to AskUserQuestion (`split-anyway | reduce-finding | defer`); do NOT silently demote to additive.

Compose the plan:

```
{
  "run":      "{run}",
  "produced_at": "<ISO-8601>",
  "operations": [
    {
      "finding_id":  "...",
      "op":          "edit" | "replace" | "split" | "rename" | "retire" | "create",
      "target":      "<repo-relative path>",
      "split_into":  ["<paths>"],     // only when op == split
      "merge_sources": ["<paths>"],   // only when op == merge
      "doc_only":    true | false,    // true if target only README/apex-core/overview/CLAUDE.md
      "predicted_delta_lines": <int>  // best-effort estimate; computed for-real in Phase 4
    },
    ...
  ]
}
```

Write to `.claude-tmp/admin-apex-active/{run}-evolve-plan.json` (note: same path/schema as admin-apex evolve.md task 5 produces; this lets Phase 3 hand off without translation).

Validate against `~/.claude/skills/admin-apex/schemas/evolve-plan.schema.json` via the standard `_validate.py producer_validate` helper. On schema failure, abort with explicit error -- the plan is malformed.

## Step 3: Apply

Two paths.

### 3a. Semantic / replace ops -- inline Edit

For each `op == edit` or `op == replace` operation:

1. Read the target file (full).
2. Apply the edit via the Edit tool. Use `replace_all` only when the rename is unambiguous across the file (e.g., a renamed symbol).
3. Re-read the target file; compute actual `delta_lines` (`new_total - old_total`).
4. Append the operation to `.claude-tmp/admin-apex-active/{run}-applied-ops.json` with the **actual** `delta_lines`.
5. Append the target path to `.claude-tmp/admin-apex-active/{run}-dirty-paths.txt`.

If an Edit tool call fails (string not found, ambiguous), surface AskUserQuestion (`retry-with-context | skip-finding | abort-run`); never silently move on.

### 3b. Structural ops -- delegate to evolve.md

For any operation in `{create, rename, split, merge, retire, schema-add, schema-remove, hook-add, hook-remove}`:

1. **Read and follow** `~/.claude/skills/admin-apex/evolve.md` task 6 ("Apply ops"). Inputs are already in place: `{run}-evolve-plan.json` (Phase 2 wrote it; same schema), `{run}-inventory.json` (run `bash skills/admin-apex/scripts/inventory-apex.sh --out .claude-tmp/admin-apex-active/{run}-inventory.json` first if absent).
2. evolve.md handles re-snapshot drift detection per op, applies via Edit/Write/Bash with `grep-apex-refs.sh` ref-rewriting, appends to `{run}-applied-ops.json` + `{run}-dirty-paths.txt`.
3. Mid-flight drift -> evolve.md surfaces `restart | commit-partial | rollback`. Apex-improve treats `restart` as exit-cleanly-and-let-user-re-invoke; `commit-partial` -> proceed to Phase 4 with ops-so-far; `rollback` -> evolve.md handles git restore + exit.

Skip the admin-apex audit (tasks 2-4) entirely -- the plan came from session-reflection signals, not drift. evolve.md task 6 does NOT depend on having a `{run}-drift-report.json` on disk; it only reads the plan + the inventory.

## Step 4: Cleanup

After ALL operations complete (or after `commit-partial` was selected in 3b):

### 4a. Archive consumed signals

```
ARCHIVE_DIR="$HOME/.claude/tmp/improvements-archive"
mkdir -p "$ARCHIVE_DIR"
DATE=$(date -u +%Y-%m-%dT%H-%M-%SZ)
TARGET="$HOME/.claude/tmp/apex-workflow-improvements.md"
[[ -s "$TARGET" ]] && {
  cp "$TARGET" "$ARCHIVE_DIR/${DATE}-workflow-improvements.md"
  : > "$TARGET"   # truncate live file
}

TECH="$HOME/.claude/tmp/tech-updates.md"
# Tech-updates archive is owned by apex-tech-watch (30-day rotation).
# apex-improve does NOT truncate tech-updates.md -- the tech-watch archive
# rotation is the single source of truth for that file's lifecycle.
```

Truncating `apex-workflow-improvements.md` is safe: the next session's reflect-traces.sh will append fresh blocks. Archive is keyed by ISO timestamp so multiple runs in the same day don't collide.

### 4b. Stamp version

```
claude --version | awk '{print $1}' > "$HOME/.claude/tmp/apex-claude-code-version.txt"
```

This closes the version-drift signal until the next CC update bumps the binary.

Add `~/.claude/tmp/apex-claude-code-version.txt` to `{run}-dirty-paths.txt` only if its content actually changed -- `git diff --quiet` check before staging. (The file is in `~/.claude/tmp/` which is `.gitignored`; this stamp is local-state only and **does not get committed**. The check is just hygiene.)

## Step 5: Report

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

If `Net delta_lines > +50` for the run OR if `additive` ops > 1, append:

```
Note (Principle 3): this run grew the framework by N lines / created M new files.
Review whether the underlying findings could have been satisfied semantically;
heavy growth is a signal you may be on the wrong track.
```

This note is **informational** -- the run still committed. It is the principled-3 enforcement: visible accretion that a human can act on.

## Subagent invocation contract

When `apex-eod` step 3 runs apex-improve as a subagent, the prompt template is:

```
ASCII only. No tables, no diagrams. Read and follow all instructions in
~/.claude/skills/apex-improve/SKILL.md. Execute every step. You are running
as a subagent under apex-eod -- do NOT commit or push (apex-eod step 5
owns the inline commit). Report the Phase 5 summary verbatim.
```

apex-eod's subagent harness is the only commit driver in EOD context. Standalone `/apex-improve` invocations leave the commit to the user (`git status` after the run shows the dirty paths; user can `/admin-apex` audit+apply or commit manually).

## Cap-reached / no-progress abort

If Phase 3 cannot apply any operation (every Edit fails or every structural op hits drift), exit with:

```
apex-improve: 0 ops applied; signals preserved for next run.
```

Do NOT truncate `apex-workflow-improvements.md` in this case -- nothing was consumed. The next run gets the same inputs.

## What this skill does NOT do

- Does NOT scout, plan teammates, or run /apex's verify-fix loop -- this is an out-of-band meta-task on the apex framework itself, not on user code.
- Does NOT touch project app code, run project lint/build, or modify `.env*`.
- Does NOT push -- standalone runs leave commit to user; under apex-eod step 3, apex-eod step 5 owns the commit.
- Does NOT mirror to the public repo -- mirroring is admin-apex task 10 only. apex-improve runs that touch publicly-mirrored files (apex-core.md, agents/**, skills/apex/**) leave them dirty for the next admin-apex run to mirror.
- Does NOT bypass the file-health hook -- if a Phase 3a semantic edit would push a file past 400 lines, the hook fires and apex-improve must AskUserQuestion (`split-now | reduce-edit | abort`). Same gate any apex skill respects.
- Does NOT decide that a tech-update is irrelevant on its own -- if uncertain whether to apply a tech-watch finding, defer it (write to `{run}-deferred-findings.json`) rather than guess.

See `~/.claude/skills/admin-apex/evolve.md` for the structural-ops engine; `~/.claude/skills/apex/shared-guardrails.md` for safety paths and JSON-Schema validation; `~/.claude/skills/apex-tech-watch/SKILL.md` for the upstream tech-updates fetcher.
