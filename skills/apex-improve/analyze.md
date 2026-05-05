---
name: analyze
description: apex-improve Step 2 - signal extraction. Reads workflow-improvements.md / tech-updates.md / apex-claude-code-version.txt, extracts findings per source-specific rules (dedup, cluster, severity), caps at 12, writes {run}-findings.json (+ {run}-deferred-findings.json for overflow).
---

# analyze (apex-improve Step 2)

Spec: `skills/apex-improve/SKILL.md` Step 2.

## Inputs

The three files in the SKILL.md "Inputs" table. Read any that exist; tolerate empty / missing per the table contract.

## Output

`.claude-tmp/admin-apex-active/{run}-findings.json` - JSON array of finding objects:

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

**Cap: 12 findings per run.** If more surface, keep the highest-severity 12 and log the rest to `.claude-tmp/admin-apex-active/{run}-deferred-findings.json` for a future run (the `{run}-deferred-findings.json` artifact is preserved across SessionEnd by `cleanup-run.sh`).

## Source-specific extraction

### workflow-improvements.md

Block-structured. Two block kinds:

- `## {session} - heuristics - {ts}` (always present per session). Read `gap_signals` / `fix_attempts` / `verbose_traces` counts. High counts across many sessions = chronic pattern -> finding.
- `## {session} - {phase} - {ts}` (Haiku reflector, present every session). Read `gaps:` / `fixes-observed:` / `improvements:` / `workflow-respected:` / `token-reductions:` lines. Each non-trivial entry is a candidate finding. Two extra parsing rules: (a) `workflow-respected: yes` is a zero-finding signal - drop pre-cluster, do NOT count toward severity (mirrors the SKIPPED-no-inputs sentinel handling); any other body becomes one finding per `step-X: <deviation>` segment, `candidate_op: "semantic"`, `target_files` derived from the named step's spec file (e.g., `step-6` -> `skills/apex/discover.md`). (b) `token-reductions:` entries always carry `candidate_op: "semantic"` and `target_files` derived from the named step; cluster across sessions like other reflector lines (3+ identical reductions -> severity high).

**Dedup adjacent identical blocks** (same `{token}+{phase}+{ts}` header AND byte-identical body) before clustering. Older logs contain reflector double-write artifacts (Haiku occasionally emitted the structured block twice in one tool-call sequence; the once-only contract is now in `agents/reflector.md` Output, but pre-fix logs persist). Treat back-to-back duplicates as one block; do NOT inflate cluster severity.

**Drop SKIPPED-no-inputs sentinels** (`## {token} - {phase} - SKIPPED-no-inputs - {ts}` - no body lines). These are reflector outputs from runs where both snapshot and manifest were absent (per `agents/reflector.md` Empty-input gate). Treat as zero-finding signals - drop pre-cluster. Do NOT count them toward severity or cross-session patterns.

**Cluster across sessions**: 3+ Haiku blocks suggesting the same improvement -> severity **high**. Single-session one-off -> **low** (often noise).

### tech-updates.md

Block-structured by source + date. Each block points at a tech-watch URL. Two questions per block:

1. Does this affect any apex file? (grep symbol names from the block against `skills/apex/**`, `agents/**`, `apex-core.md`)
2. If yes, is the apex file already aligned, or out of date?

Drop blocks with no apex-file hit (informational only - not every tech update is actionable).

**Missing or stale tech-updates.md**:
- File missing -> emit one finding: `summary: "tech-watch never run; user has not deployed weekly automation"`, `candidate_op: "semantic"`, `target_files: []`.
- mtime > 14 days -> emit one finding: `summary: "tech-watch stale (last run YYYY-MM-DD)"`, `candidate_op: "semantic"`, `target_files: []`.

Both findings carry `target_files: []` so Step 3 plan cannot promote them to ops; they surface in Step 6 report only and prompt the user to invoke `/apex-tech-watch` or set up the launchd/cron per `skills/apex-tech-watch/SKILL.md`.

### version-drift

If `apex-claude-code-version.txt` is missing or older than the current CC version (`claude --version` parsed), emit ONE finding: `summary: "review CC release notes since version X for behavior changes; check apex hook configurations and skill prompts for affected primitives"`. This is usually a meta-finding pointing at apex-tech-watch's most recent fetch.

## Empty case

If all three sources produce zero findings, write `findings.json` as `[]` and let SKILL Step 2 surface the no-signals exit. Do NOT skip the file write - SKILL needs a deterministic artifact to read.

## What this step does NOT do

- Does NOT write `evolve-plan.json` - that is `plan.md` (Step 3).
- Does NOT mutate any apex file - that is `apply.md` (Step 4).
- Does NOT decide on its own that a tech-update is irrelevant - if uncertain, defer (write to `{run}-deferred-findings.json`) rather than guess.
