---
name: apex-audit-matrix
description: Coverage-tracked security audit. Deterministic enumeration + LLM analysis + persistent coverage state. Replaces probabilistic audit runs with convergent, incremental verification.
triggers:
  - apex-audit-matrix
---

<!-- Called by: standalone via /apex-audit-matrix, SKILL.md Step 1.5 (auto-routing), or referenced by apex-scout.md audit mode -->

# apex-audit-matrix - Coverage-Tracked Audit

Transforms LLM-based auditing from probabilistic to convergent by separating WHAT to check (deterministic enumeration) from HOW to check (LLM analysis) and tracking WHAT WAS checked (persistent coverage state).

## Arguments

Parse arguments for mode:
- `--catalog <path>`: Path to criteria catalog (default: `.claude/audit-criteria/security.md`)
- `--root <path>`: Project root override (default: current working directory). Use `~/.claude/skills` for skill-quality audits.
- `--resume <path>`: Resume from existing matrix JSON (incremental re-audit)
- `--scope <paths>`: Comma-separated file paths to limit scope
- `--batch-size <n>`: Max cells per scout batch (default: 20)
- `--verdicts-dir <dir>`: Persistent verdict storage directory (default: `{project-root}/.claude/audit-verdicts/`)
- `--no-persist`: Skip auto-save/auto-load of persistent verdicts
- `--evaluator-model <model>`: Model for evaluator agent in Phase 2.5 (default: reads from agents/evaluator.md model field, fallback: "sonnet")
- No arguments: generate fresh matrix using default catalog, then run Phase 2

## Phase 0: Catalog Health Check

Before generating the matrix, validate the catalog against the current codebase state.

1. Run the health check script:
   ```
   python3 ~/.claude/skills/apex/scripts/audit-catalog-health.py \
     --catalog-dir {catalog-dir} \
     --project-root {project-root}
   ```
   Where `{catalog-dir}` is the directory containing the catalog file. Derive from `--catalog` path: `dirname({catalog-path})`. Default: `.claude/audit-criteria/`.

2. Print the summary line (catalogs, criteria).

3. If issues found, print a brief summary grouped by type:
   - STALE_TARGET: print criterion ID and suggestion
   - SIZE_EXCEEDED: print catalog name and count/line count
   - COUNT_MISMATCH / MISSING_COUNT: print declared vs. actual
   - SOURCE_DRIFT: print source file and commit count

4. Proceed to Phase 1 regardless -- health issues are informational, not blocking. The user can address them after the audit run.

## Phase 1: Matrix Generation

1. Resolve catalog path. Default: `{project-root}/.claude/audit-criteria/security.md`. If catalog does not exist, print `ERROR: Catalog not found at {path}. Create one with criteria definitions.` and stop.

2. **Fresh run (no --resume):** Run the enumeration script:
   ```
   python3 ~/.claude/skills/apex/scripts/enumerate-audit-matrix.py \
     --catalog {catalog-path} \
     --project-root {project-root} \
     [--scope {scope}] \
     [--verdicts-dir {verdicts-dir}] \
     [--no-persist]
   ```
   Parse the output for the matrix JSON path. Print: `MATRIX GENERATED: {path}`.

   **Sparse format (v2.0+):** The matrix array only contains applicable cells (unchecked, pass, fail, recheck, remediated, scout N/A with evidence). Pre-filter N/A cells are stored as count-only metadata in `pre_filter_na: {count: N, by_criterion: {...}}` -- not as individual cell objects. This reduces matrix size by ~60%.

   **Auto-load behavior:** Without `--resume`, the script auto-loads from `{verdicts-dir}/{theme}-verdicts.json` if it exists (unless `--no-persist` is set). This makes `--resume` optional for subsequent runs -- the persistent store acts as implicit resume. File-hash-based change detection compares stored `file_hash` (git hash-object) against the current file hash: unchanged files carry forward their verdicts, changed files get `recheck` status. New files/criteria get `unchecked` status.

3. **Resume run (--resume <path>):** Run the enumeration script with --resume:
   ```
   python3 ~/.claude/skills/apex/scripts/enumerate-audit-matrix.py \
     --catalog {catalog-path} \
     --project-root {project-root} \
     --resume {resume-path} \
     [--scope {scope}] \
     [--verdicts-dir {verdicts-dir}] \
     [--no-persist]
   ```
   This preserves pass/fail cells, converts remediated to recheck, and adds new cells. Print: `MATRIX RESUMED: {path}`.

4. Read the generated matrix JSON. Extract summary stats. Print:
   ```
   COVERAGE: {coverage_pct}% ({pass} pass, {fail} fail, {unchecked} unchecked, {na} N/A)
   REMAINING: {unchecked + recheck} cells to verify across {unique_files} files
   ```

5. If unchecked + recheck == 0: print `AUDIT COMPLETE: 100% coverage.` and stop. Otherwise proceed to Phase 1.5.

## Phase 1.5: Mechanical Pre-Check

Deterministic shell verification for cells that do not require LLM judgment. Skips LLM scouts for file-existence, pattern-grep, and count-based checks.

### Step 1: Classify cells

For each unchecked/recheck cell, classify as "mechanical" or "judgment":

**Mechanical** -- criterion can be verified by shell commands alone:
- Criterion has type markers `exists`, `grep`, or `count` in the catalog
- Criterion description starts with "File X exists", "Pattern Y appears in", "At least N instances of"
- Criterion whose `property` field is a pure existence/presence assertion (no behavioral analysis)

**Judgment** -- everything else (behavioral analysis, ownership tracing, design review, security reasoning).

### Step 2: Run mechanical checks

If mechanical cells > 0:
```
python3 ~/.claude/skills/apex/scripts/mechanical-audit.py \
  --matrix {matrix-path} \
  --catalog {catalog-path}
```

The script:
- Reads the matrix JSON and catalog
- For each mechanical cell: runs the appropriate check (file exists, grep pattern, count lines)
- Uses `git hash-object` for file hash consistency
- Outputs updated matrix JSON to stdout
- Prints summary: `MECHANICAL: {n} cells checked, {pass} pass, {fail} fail`

### Step 3: Update matrix

Parse the script output. Update the matrix JSON with mechanical verdicts (same cell schema as Phase 2 Step 3). Recompute summary stats and persist.

Print: `MECHANICAL PRE-CHECK: {n} cells resolved, {remaining} cells need LLM verification`

If all remaining cells are resolved, skip Phase 2 and proceed to Phase 2.5. Otherwise proceed to Phase 2.

## Phase 2: Verification

### Step 1: Group cells by file

Group unchecked/recheck cells by target file. This lets scouts read each file once and check all applicable criteria. Sort groups by file with highest number of unchecked criteria first (maximize coverage per scout).

### Step 2: Distribute to scouts

**Batch sizing.** Each scout gets a batch of files, with total cells per scout <= batch-size (default 20). One scout per batch. Scale scout count to cover all unchecked cells, capped at 6 concurrent scouts.

**If total unchecked cells <= batch-size:** Single inline verification (no scout spawning). Read each file and check criteria directly.

**If total unchecked cells > 60 AND unique target files > 15 (Agent Teams path):** Use Agent Teams instead of subagent scouts to prevent parent context exhaustion.
1. Derive team-name from audit theme: `audit-{theme}-{session-id-prefix}` (e.g., `audit-security-a1b2c3`).
2. Create the team via TeamCreate.
3. Create shared tasks per batch (same batch sizing as subagent dispatch -- cells per task <= batch-size). Each task subject: `Audit batch {n}: {file-count} files, {cell-count} cells`.
4. Each teammate receives: inline criterion definitions (from matrix JSON `criteria_definitions`), their assigned batch of file+criterion pairs, and the scout prompt template below.
5. Collect verdicts via TaskList/TaskGet after all teammates complete. Parse verdict blocks from task output fields.
6. **Fallback:** If TeamCreate fails, fall back to subagent dispatch (next paragraph) and log: `AGENT TEAMS UNAVAILABLE: falling back to subagent dispatch`.
7. **Batch overflow (batches > 6):** Spawn min(batch-count, 6) scouts for the first N batches. When a scout completes its batch, mark the batch task as completed immediately, then reassign the scout to the next unstarted batch via SendMessage with the new batch payload. When no unstarted batches remain, shut down returning scouts via SendMessage with a completion signal. Never leave a batch task unmarked -- update status before reassignment.

Note: Agent Teams provide independent 1M-token context windows per worker, preventing parent context exhaustion on large audits. Below 60 cells, subagent dispatch is more efficient (lower overhead).

**If total unchecked cells > batch-size (and not Agent Teams path):** Launch parallel scouts (subagent_type: `apex-scout`) -- ALL Agent tool calls in a SINGLE response. The agent definition pre-loads output format and key principles; the inline prompt template below supplements with cell-specific instructions.

**Model escalation rule.** Cells requiring cross-file behavioral verification use `model: "opus"` instead of the default `model: "sonnet"`. A cell is "cross-file behavioral" when any of these hold:
- Criterion ID matches `AUTH-*` or `FLOW-*` patterns
- Criterion description or property contains: "call-chain", "data-flow", "cross-file", "trace.*through", "ownership"
- Cell's criterion targets multiple files (comma-separated target globs resolving to 2+ files)

Batch cells by model: sonnet-model cells and opus-model cells go in separate batches. Each batch's Agent call uses the appropriate model. Single-file mechanical/existence checks stay on sonnet.

Scout prompt template (construct from matrix JSON `criteria_definitions` field -- embed only the definitions for criteria in this batch):
```
ASCII only. No tables, no diagrams. You are verifying specific security criteria against specific files for a coverage-tracked audit. For each cell, report a verdict.

RULES:
(1) Read the target file before checking any criterion against it.
(2) For each cell, report: PASS, FAIL, or N/A with evidence.
(3) PASS requires citing file path + line or content proving compliance.
(4) FAIL requires citing what was found instead (or confirming absence after search).
(5) N/A only when the criterion is structurally inapplicable (not just because the check passed).
(6) For ownership/auth criteria: trace the userId through the actual query chain. Function existence alone is not PASS.
(7) For rate limiting criteria: check the actual middleware applied, not just the route definition.
(8) For OPEN-01: review the file for any security concern not covered by the named criteria. If none found, PASS with "No additional concerns."

OUTPUT FORMAT (one block per cell):
---
TARGET: {relative file path}
CRITERION: {criterion ID}
VERDICT: {PASS|FAIL|N/A}
EVIDENCE: {1-2 lines: what you found, with line reference}
---

CRITERIA DEFINITIONS:
{for each unique criterion ID in this batch, from matrix JSON criteria_definitions}
## {ID}
- description: {description}
- property: {property}
- pass: {pass}
- fail: {fail}
- severity: {severity}
{end for}

FILES TO VERIFY:
{for each file in batch}
- {file path}: check {criterion IDs}
{end for}
```

### Step 3: Collect verdicts

Parse scout output. For each verdict block, update the corresponding cell in the matrix JSON:
- Set `status` to the verdict (pass/fail/not_applicable)
- Set `evidence` to the evidence string
- Set `checked_at` to current ISO timestamp
- For cells that were "recheck": clear `remediated_at`
- Note: cells also carry `file_hash` (set at matrix generation time). No action needed here -- Phase 2 reads/writes verdicts, not hashes.

### Step 4: Persist and report

1. Update the matrix JSON file:
   - Recompute summary stats via `compute_summary(matrix, data.get("pre_filter_na", {}).get("count", 0))`
   - Update the `updated` timestamp
   - Write back to the same file path
   - Auto-save persistent verdicts (unless `--no-persist`)

2. Print coverage report:
   ```
   COVERAGE UPDATE: {old_pct}% -> {new_pct}%
   THIS PASS: {new_pass} pass, {new_fail} fail, {new_na} N/A out of {cells_checked} cells
   REMAINING: {unchecked + recheck} cells across {remaining_files} files
   FINDINGS: {fail_count} failures found
   ```

3. If fail_count > 0, print failure summary:
   ```
   FAILURES:
   1. {criterion_id} in {file}: {evidence}
   2. ...
   ```

4. If unchecked + recheck > 0 and coverage < 100%:
   - If remaining cells <= batch-size: launch a single supplementary scout (same agent type and prompt template as Step 2) to complete coverage. Collect verdicts per Step 3, then recompute and persist. Print: `SUPPLEMENTARY: {remaining} cells -> 1 scout`.
   - If remaining cells > batch-size or supplementary scout also leaves cells unchecked: print `Run /apex-audit-matrix --resume {matrix-path} to continue verification.`

5. If coverage == 100%:
   Print: `AUDIT COMPLETE: 100% coverage. {total_pass} pass, {total_fail} fail across {total_files} files.`

## Phase 2.5: Evaluator Loop

Independent re-verification of PASS verdicts to catch false positives. Skipped when total PASS cells < 10 (insufficient sample size).

### Step 1: Filter and sample

1. Count PASS cells in the matrix. If < 10, print `EVALUATOR: skipped (only {n} PASS cells, minimum 10)` and proceed to Phase 3.

2. Run the sampling script:
   ```
   python3 ~/.claude/skills/apex/scripts/evaluator-sample.py \
     --matrix {matrix-path} \
     --sample-pct 25 \
     --min-sample 3
   ```
   Parse JSON output. Print: `EVALUATOR: sampling {sampled} of {eligible} eligible PASS cells`.

### Step 2: Launch evaluator agent

If `--evaluator-model` argument provided, use it as the explicit model parameter. Otherwise, omit the model parameter from the Agent tool call -- the agent definition (`~/.claude/agents/evaluator.md`) specifies the default model. Using a different model from the scout model provides diversity of blind spots for false positive detection.

Per shared-guardrails #1, launch in foreground without a name -- background/named agents cause polling loops and prevent direct verdict extraction from the return value.

Launch a single unnamed foreground agent (subagent_type: `apex-evaluator`, model: {evaluator-model if provided}, no `name` parameter) with the sampled cells:

```
<role>You are an independent evaluator re-verifying PASS verdicts with fresh context. Your purpose is to catch false PASS verdicts that scouts may have issued incorrectly.</role>

<rules>
(1) Read each target file fresh -- do not rely on prior context or original evidence.
(2) Read the criterion definition from the catalog before checking.
(3) Independently determine whether the code satisfies the criterion.
(4) For ownership/auth criteria: trace userId through the full query chain. Function existence alone is not PASS.
(5) For rate limiting: verify actual middleware attachment, not route presence.
(6) Be skeptical -- you are looking for errors in the original verdict.
(7) ASCII only. No tables, no diagrams.
</rules>

<output-format>
For each cell:
---
TARGET: {relative file path}
CRITERION: {criterion ID}
VERDICT: {PASS|FAIL}
EVIDENCE: {1-2 lines with line references}
ORIGINAL: PASS
DISPUTE: {yes|no}
---
</output-format>

<example>
---
TARGET: apps/api/app/controllers/videos_controller.ts
CRITERION: AUTH-01
VERDICT: FAIL
EVIDENCE: Line 45: findOrFail(params.id) without .where('userId', userId) -- ownership not enforced
ORIGINAL: PASS
DISPUTE: yes
---
</example>

CRITERIA DEFINITIONS:
{for each unique criterion ID in sampled cells, from matrix JSON criteria_definitions}
## {ID}
- description: {description}
- property: {property}
- pass: {pass}
- fail: {fail}
- severity: {severity}
{end for}

CELLS TO RE-VERIFY:
{for each sampled cell}
- {target}: check {criterion ID} (original evidence: {evidence})
{end for}
```

### Step 3: Process evaluator output

Verdict blocks come from the agent's return value directly -- do not poll a task output file or send messages to prod the agent. Parse the return value for verdict blocks. For each disputed cell (DISPUTE: yes):
- Set cell `status` to "fail"
- Append evaluator evidence prefixed with `[EVALUATOR]` to existing evidence
- Set `checked_at` to current ISO timestamp

### Step 4: Recompute and persist

1. Recompute summary stats via `compute_summary(matrix, data.get("pre_filter_na", {}).get("count", 0))` from audit_matrix_lib.
2. Update the matrix JSON file.
3. Auto-save persistent verdicts (unless `--no-persist`).

### Step 5: Report

Print evaluator summary:
```
EVALUATOR: sampled {n} PASS cells, {d} disputed
```

If disputed > 0, print disputed cells:
```
EVALUATOR DISPUTES:
1. {criterion_id} in {file}: {evaluator evidence}
2. ...
```

### Step 6: Iterate (cap at 2 rounds)

If > 20% of sampled cells were disputed AND this is round 1: run one more evaluator round (Steps 1-5) on the remaining undisputed PASS cells. Cap at 2 total rounds. Print: `EVALUATOR: round 2 triggered ({dispute_pct}% dispute rate)`.

After the final round, proceed to Phase 3.

## Phase 3: Remediation Integration

When findings are remediated (via `/apex` or manual fixes):

1. The user marks cells as remediated by running:
   ```
   /apex-audit-matrix --resume {matrix-path}
   ```

2. Before re-verification, the script converts remediated cells to "recheck" status.

3. Phase 2 picks up recheck cells alongside any remaining unchecked cells.

4. This creates a convergent loop: enumerate -> verify -> remediate -> re-verify -> done.

**Criteria evolution (automated pipeline).** When OPEN-01 produces FAIL findings:
1. After Phase 2 completes with OPEN-01 FAIL cells, auto-run the findings-to-catalog script:
   ```
   python3 ~/.claude/skills/apex/scripts/findings-to-catalog.py \
     --matrix {matrix-path}
   ```
   Exit 0: candidates written. Exit 1: no OPEN-01 FAIL cells found (skip silently). Exit 2: error.
2. Print: `CRITERIA CANDIDATES: {output-path}`. The output file is `{catalog-dir}/candidates-{YYYY-MM-DD}.md`.
3. The user reviews the candidates file, edits as needed, and appends accepted criteria to the main catalog.
4. Next matrix generation includes the new criteria automatically.

## Marking Cells as Remediated

To mark specific cells as remediated (after fixing the code):

```bash
python3 ~/.claude/skills/apex/scripts/mark-cells-remediated.py {matrix-path} "target:CRITERION_ID" ...
```

See `~/.claude/skills/apex/scripts/mark-cells-remediated.py` for full script.

## Relationship to Existing Audit Flow

This system complements, not replaces, the existing apex-scout audit mode:

- **apex-scout audit mode**: Document-driven audits (doc-vs-code sync, compliance, feature completeness). Probabilistic but broad discovery.
- **apex-audit-matrix**: Criteria-driven audits (security properties, invariant checking). Deterministic coverage, convergent re-runs.

For security audits specifically, prefer apex-audit-matrix. For doc-sync and compliance audits, use apex-scout audit mode. For mixed concerns, run both.

## Persistent Verdict Storage

See `~/.claude/skills/apex-audit-matrix/verdict-storage.md` for format, lifecycle, and --resume relationship.

## Catalog Design

Catalogs exist to make scout agents effective -- not to be exhaustive encyclopedias. A catalog that exhausts a scout's context window defeats its own purpose.

### Hard Limits

1. Max **60 criteria** per catalog file
2. Max **600 lines** per catalog file
3. Recommended target: 20-40 criteria (sweet spot for coverage vs. context cost)

### When to Split

A domain exceeding 60 criteria must be split into thematic sub-catalogs. Split by audit concern, not by application area:
- `oauth-security.md` (token handling, PKCE, refresh rotation)
- `channel-management.md` (connect, disconnect, limits, reconnect)
- `posting-pipeline.md` (validation, scheduling, platform dispatch)

Each sub-catalog runs as a separate `/apex-audit-matrix --catalog` invocation. The audit-matrix system handles one catalog per run by design.

### Completeness Definition

A catalog is complete when:
1. All **CRITICAL** and **HIGH** severity properties for the theme are covered
2. Pre-filters reduce the matrix by >30% (meaningful filtering, not `.*` catch-alls)
3. OPEN-01 findings have plateaued: 2+ successive runs produce <3 new findings
4. Each criterion targets 1-5 files (not "all files in scope" except OPEN-01)

OPEN-01 is the catch-all. A catalog does not need to anticipate every possible issue -- OPEN-01 findings feed back into the catalog via `findings-to-catalog.py`.

### Metadata Discipline

The `sources` field lists authoritative source files used to derive criteria. Keep it to the key source files (docs, core services), not an exhaustive list of every file mentioned in targets. Targets are discoverable from the criteria themselves.

### What Catalogs Are NOT

- Not a specification document (use feature docs for that)
- Not a test suite (each criterion is a verifiable property, not a test case)
- Not exhaustive by design (OPEN-01 + iterative refinement handles the long tail)

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not skip Phase 1 (matrix generation) -- even on resume, the script must re-enumerate to detect new files
- Do not modify the criteria catalog during an audit run -- catalog changes take effect on the next fresh matrix generation
- Do not mark cells as pass/fail without reading the target file and checking the specific criterion
- Do not report PASS for ownership/auth criteria based on function existence alone -- trace the userId through the query chain
- Do not launch more than 6 concurrent scouts (diminishing returns, context pressure)
- Do not re-check pass cells unless the target file was modified (resume mode handles this via the enumeration script)
- Do not read the catalog file manually during the audit flow -- criterion definitions are embedded inline in scout/evaluator prompts from the matrix JSON `criteria_definitions` field. Scouts must NOT be instructed to read the catalog file. The only permitted catalog read is the metadata check in SKILL.md Step 1.5 (first 15 lines for project-root detection)
