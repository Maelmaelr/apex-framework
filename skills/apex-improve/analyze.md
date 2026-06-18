---
name: analyze
description: apex-improve Step 2 - signal extraction. Reads workflow-improvements.md / tech-updates.md / apex-claude-code-version.txt + prior-run {run}-deferred-findings.json (backlog), extracts findings per source-specific rules (dedup, cluster, severity), caps the plannable set at 12, writes {run}-findings.json + a consolidated {run}-deferred-findings.json carrying the unresolved backlog forward.
---

# analyze (apex-improve Step 2)

Spec: `skills/apex-improve/SKILL.md` Step 2.

## Inputs

The three signal files in the SKILL.md "Inputs" table. Read any that exist; tolerate empty / missing per the table contract.

Plus a fourth, session-spanning source: **prior-run `{run}-deferred-findings.json`** files in `.claude-tmp/admin-apex-active/` (see "Prior-run deferred-findings" below). These are findings a past run could not resolve; they are EXEMPT from `sweep-orphan-artifacts.sh`, so they persist across arbitrary idle gaps until this step reprocesses them.

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

**Cap: 12 on the plannable set.** `{run}-findings.json` holds at most the highest-severity 12 non-chronic findings (the set Step 3 plans). Everything else - lower-severity overflow, chronic entries, and the carried backlog - lives in the consolidated `{run}-deferred-findings.json` (see "Prior-run deferred-findings" below). That file is preserved across SessionEnd by `cleanup-run.sh` and reprocessed by the next run, not discarded.

## Source-specific extraction

### workflow-improvements.md

Block-structured. Two block kinds:

- `## {session} - heuristics - {ts}` (always present per session). Read `gap_signals` / `fix_attempts` / `verbose_traces` counts. High counts across many sessions = chronic pattern -> finding.
- `## {session} - {phase} - {ts}` (Sonnet reflector, present every session). Read `gaps:` / `fixes-observed:` / `improvements:` / `workflow-respected:` / `token-reductions:` lines. Each non-trivial entry is a candidate finding. Two extra parsing rules: (a) `workflow-respected: yes` is a zero-finding signal - drop pre-cluster, do NOT count toward severity (mirrors the SKIPPED-no-inputs sentinel handling); any other body becomes one finding per `step-X: <deviation>` segment, `candidate_op: "semantic"`, `target_files` derived from the named step's spec file (e.g., `step-6` -> `agents/discoverer.md`). (b) `token-reductions:` entries always carry `candidate_op: "semantic"` and `target_files` derived from the named step; cluster across sessions like other reflector lines (3+ identical reductions -> severity high).

**Dedup adjacent identical blocks** (same `{token}+{phase}+{ts}` header AND byte-identical body) before clustering. Older logs contain reflector double-write artifacts (Sonnet occasionally emitted the structured block twice in one tool-call sequence; the once-only contract is now in `agents/reflector.md` Output, but pre-fix logs persist). Treat back-to-back duplicates as one block; do NOT inflate cluster severity.

**Drop SKIPPED-no-inputs sentinels** (`## {token} - {phase} - SKIPPED-no-inputs - {ts}` - no body lines). These are reflector outputs from runs where both snapshot and manifest were absent (per `agents/reflector.md` Empty-input gate). Treat as zero-finding signals - drop pre-cluster. Do NOT count them toward severity or cross-session patterns.

**Cluster across sessions**: 3+ Sonnet blocks suggesting the same improvement -> severity **high**. Single-session one-off -> **low** (often noise).

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

## Resolved-by-design / explicit-wontfix auto-drop

Some findings recur from reflectors yet are settled - the behavior is intentional per an explicit user directive, or the cost they target is already mitigated. Drop these PRE-CLUSTER on BOTH tracks (fresh-source extraction AND backlog re-validation): match by `id`, record the auto-drop in the Step 6 report, never carry or plan. Add an entry ONLY on an explicit user wontfix / mitigated decision; remove the entry if its cited mitigation later changes.

- `apex-merge-precheck-scope` - precheck auto-commit scope is final per explicit user directive ("just commit, don't ask"; the `>10` prompt was deliberately removed). `apex-merge/SKILL.md:39` documents the contract; the auto-force allowlist (`SKILL.md:132`) is the only sanctioned extension point.
- `merge-precheck-ordering` - the recurring "defer precheck auto-commit until step-2 discovers a needs-merge branch / warn before committing" signal is settled: the warn half already fires (source-path WARNING + `<run>-precheck-auto-committed.txt` sidecar, `apex-merge/SKILL.md:49-52,72`), and the defer-until-after-discovery + harness-file-stash halves contradict the documented unconditional auto-commit (zero-branch commit is intentional, `SKILL.md:39,82`). Mitigated + resolved-by-design; sibling to `apex-merge-precheck-scope`.
- `apex-scope-overinclusion-docs` - the doc pre-load cost is already mitigated: `08-execute.md` E3.1/E3.6 surface goal-unmatched docs reference-only / on-demand (never pre-loaded), and the `doc_surface` fold (`discoverer.md:109`) is intentional to stop reactive late-append of architecture / rule docs.
- `review-doc-stale-inline` - applying review doc-stale fixes inline at the review step contradicts the reviewer "Reports only - never edits" invariant (`agents/reviewer.md:72`, `skills/apex/steps/10-verify.md:85`); the clean invariant outweighs saving one dispatch round-trip. Explicit user wontfix.
- `redundant-reread` - step-8 dispatch re-reading discovery-skip-inlined seeder files is already mitigated by `08-execute.md` E3.2 pre-read + E3.6 helper_snapshot inlining; low residual token-reduction, repeatedly bloat-deferred onto the hot-path file. Explicit user wontfix.
- `step8-export-kind-verify` - single-session evidence never reinforced across 7 carries; one-off, not a pattern. Explicit user wontfix.
- `admin-apex-inventory-post-skip` - token micro-optimization on an out-of-band skill; fast-path complexity outweighs the savings. Explicit user wontfix.
- `review-gate-widen-fix-sessions` - widening raises review-dispatch cost on every fix session for 3-session anecdotal risk; the doc-consistency carve-out + complexity triggers (`10-verify.md`) already cover the surface. Explicit user wontfix.
- `doc-consistency-carveout-step11-suppress` - suppression conflicts with the carve-out's planned-scope keying (step-11 docs land AFTER the gate; `10-verify.md:26`); the code-only review hop is ~200-token noise, not worth weakening the gate. Explicit user wontfix.
- `review-rereview-skip-known-rejected` - an attempt-2 re-review skip needs new previously-rejected-false-positive tracking state on the hot-path re-review contract (`10-verify.md:70`); the gate-erosion risk outweighs saving one already-bounded reviewer call (cap 2 reviews + 1 fix). Explicit user wontfix.
- `reviewer-premise-precheck` - a pre-fix domain-contradiction check adds a hot-path review-fix gate that can fail-closed against valid findings, to save one already-bounded inline rejection; the reviewer false-positive is ALREADY caught + rejected at fix-dispatch time (`08-execute.md` post-dispatch reconciliation). Same gate-erosion trade as the sibling `review-rereview-skip-known-rejected`. Explicit user wontfix.
- `lessons-step37-count-gate` - gating the Step 3.7 non-obvious filter on an unverified-count threshold would skip mandatory leanness enforcement (the filter drops obvious entries from BOTH the verified-kept AND unverified sets, `apex-lessons/triage.md` Step 3.7); drop=0 in one run does not predict the next, and the phase-level simplified-mode count gate (`apex-lessons/analyze.md` Step 0b) already covers the genuinely-tiny set. Explicit user wontfix.
- `pnpm-add-worktree-relink` - a pnpm-specific shared/virtual-node_modules sibling-relink hazard rule would over-specify the generic executor contract (`agents/executor.md:36` is a hot-path dense paragraph); the existing "run the commands your change produces" rule (deps installs + lockfile updates) already covers it at the right altitude. Niche single-session datapoint. Explicit user wontfix.
- `decouple-complexity-hint` - a `decouple` `complexity_hint` variant conflates a magnitude axis (low|medium|high, `04-hypothesis.md:5`) with a task shape, muddying a clean enum and inviting a slippery slope (migrate, refactor, ...); the dead-code-removal concern is already expressible via the `alternatives` + `goals` decomposition. Explicit user wontfix.
- `merge-single-branch-discovery-overhead` - the unconditional `<run>-discovery.json` write is the complete-artifact-set-for-audit decision (`apex-merge/SKILL.md:85` keeps discovery.json + `[]`-sentinel merge-result.json regardless of branch count); inlining for <=1 branch trades the audit trail for one JSON round-trip. Sibling to `merge-sidecar-omit`. Explicit user wontfix.
- `merge-sidecar-omit` - conditionally omitting `<run>-precheck-auto-committed.txt` weakens the audit half of the settled merge-precheck-observability mitigation (`apex-merge/SKILL.md:49`) for a low token saving. Explicit user wontfix.
- `gs-hook-split` - lowering the scout B0.7 `allowed_files` floor (~3-8, `08-execute.md:35`) spawns scouts on tiny goals project-wide to catch a single-session ~10-call overrun that clears neither the >60 tool_uses nor >180k token single-dispatch reaction. Bad cost/benefit. Explicit user wontfix.
- `budget-guard-warn-skip` - the admin-apex task-3 `approaching-budget` WARN is intentional standing leanness pressure routed to `defer` by design (`audit.md:42`); skipping it deletes the signal, not the work. Explicit user wontfix.
- `dcp-delegate-discipline` - reflector advisory self-concluded "no structural change warranted"; the delegate-the-investigation idiom already exists (`apex-core.md` context-isolation), so a vague "strengthen" only bloats a central spec. Explicit user wontfix.
- `admin-mirror-followup-seed` - the task-9 stage / task-10 mirror split is intentional (`admin-apex/SKILL.md:42`); seeding followups into task-9 conflates the two phases. Explicit user wontfix.
- `economy-review-multifile` - widening economy-tier review triggers raises cost on the cheap path, eroding the tier's purpose; sibling to the settled `review-gate-widen-fix-sessions`. Explicit user wontfix.

## Prior-run deferred-findings (backlog ingestion)

Past runs write `{run}-deferred-findings.json` (cap-overflow + uncertain-defer); `cleanup-run.sh` preserves them across SessionEnd AND they are exempt from `sweep-orphan-artifacts.sh`, so they survive indefinitely until this step reprocesses them. Without this ingestion they would carry forward forever without ever reaching an op.

**Consumable set**: every `.claude-tmp/admin-apex-active/*-deferred-findings.json` where the token != the current run AND the producing `{token}.json` manifest is **absent** (run complete). The manifest-absent guard mirrors `sweep-orphan-artifacts.sh` so a live concurrent run's in-flight deferred file is never consumed. Producer is irrelevant - admin-apex audit deferrals are the same finding class and fold in here.

For each consumable finding:

0. **Staleness re-validation (before incrementing)**: confirm the finding's target condition still reproduces - grep the named `target_files` for the gap symbol, re-run the cited detector, or check an impl marker named in `evidence`. If it no longer holds (impl landed, debt paid, detector clean), DROP the finding entirely (do NOT carry or increment) and record the auto-retire in the Step 6 report. This gate runs FIRST so a resolved finding never climbs toward `chronic` and nags forever. Only still-reproducing findings reach step 1.
1. **Increment `deferrals`** (absent -> treat as 0, so first carry-over becomes 1).
2. **Chronic gate**: `deferrals >= 3` -> set `chronic: true`. Chronic findings are report-only - excluded from the plannable pool (they keep failing the same AskUserQuestion / design-decision gate, so re-planning churns) but carried forward in the consolidated file (non-lossy) and counted in the Step 6 report so the user is nudged to decide manually.
3. Otherwise merge into the candidate pool alongside the fresh-source findings.

**Dedup by `id`** across the merged pool: a fresh-source finding wins over a carried one of the same `id` (newer evidence), inheriting the higher `deferrals` count. (Semantic near-dups with different ids are left to the human / plan stage - do NOT build a fuzzy matcher; Principle 3.)

**Consolidation outputs** (single backlog-minus-applied invariant):

- `{run}-findings.json` = the top-12 **non-chronic** pool entries by severity (the set Step 3 will plan). Cap is on the plannable set, not the backlog.
- `{run}-deferred-findings.json` = the FULL deduped pool (carried + fresh, `deferrals` incremented, `chronic` flagged) - i.e. everything ingested this run. `finalize.md` Step 5b prunes whatever Step 4 applied, leaving exactly the unresolved backlog under the live run token. Overflow beyond 12 stays here and is never planned this run.
- `{run}-consumed-deferred.txt` = one path per consumed prior file. `finalize.md` deletes these only AFTER the consolidated file is written + pruned (write-new-then-delete-old; a crash before finalize leaves the originals intact).

Backlog durability: the consolidated file is EXEMPT from `sweep-orphan-artifacts.sh` (the deferred-findings exclusion), so an arbitrarily long idle gap with no apex-improve run never drops it - the backlog is kept until a run consumes it. Steady state still keeps at most one deferred file (each run consumes all manifest-absent predecessors, consolidates into one, and `finalize.md` deletes the consumed originals), so the exemption cannot let the backlog accumulate unbounded.

## Empty case

If all three signal sources produce zero findings AND the consumable deferred-findings set is empty, write `findings.json` as `[]` and let SKILL Step 2 surface the no-signals exit. Do NOT skip the file write - SKILL needs a deterministic artifact to read. A non-empty deferred backlog is NOT a no-signals exit: write the consolidated `{run}-deferred-findings.json` + `{run}-consumed-deferred.txt` even when the live signals are empty, so the backlog carries forward (and, if any survivors are non-chronic, populate `findings.json` so Step 3 can plan them).

## Deferral + crash-safe ordering

When uncertain whether a tech-update is relevant, defer it (write to `{run}-deferred-findings.json`) rather than guess. This step records consumed prior deferred-findings paths in `{run}-consumed-deferred.txt`; `finalize.md` Step 5b deletes those files after the consolidated file is written and pruned (crash-safe ordering). Planning is `plan.md` (Step 3); op application is `apply.md` (Step 4).
