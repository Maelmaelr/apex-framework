<!-- Referenced by: apex-apex.md Step 2.6 (document creation), apex-tail.md Agent 3 (document mutation), SKILL.md Step 1 (batch-mode detection) -->

## Session Type Reference

1. `audit-remediation` -- path: `.claude-tmp/audit/*.md`, ID prefix: BP-, completed lists key: `fixed_items`, priority order: critical > high > medium > low
2. `prd-implementation` -- path: `.claude-tmp/prd/*.md`, ID prefix: REQ-, completed lists key: `implemented_items`, priority order: must_have > should_have > nice_to_have
3. `audit-matrix-remediation` -- path: `.claude-tmp/audit-matrix/*.json`, cell key format: `target:criterion`, status field: `status`, timestamp field: `remediated_at`

## Audit Document Format

YAML front matter:

```yaml
name: audit-<short-title>-<uid>
created: <today>
updated: <today>
fixed_items:
  critical: []
  high: []
  medium: []
  low: []
progress:
  critical: { total: N }
  high: { total: N }
  medium: { total: N }
  low: { total: N }
```

`fixed_items` tracks remediated BP-IDs per tier. Remaining per tier: `total - len(fixed_items.{tier})`.

Body structure:
- Summary: violation count and file count only (e.g., "23 findings across 13 files"). No bold, no bullet lists, no clean-files list.
- Criteria definitions: flat list, one per line (e.g., "C1-SIZE: >500 lines"). No tables.
- Per-file findings: one section per file, findings tagged with sequential BP-IDs (`[BP-01]`, `[BP-02]`, ...) globally across the document, each item on its own line.
- Priority ranking: BP-IDs grouped by Critical / High / Medium / Low tiers. No narrative descriptions per tier -- the tier name is sufficient.
- No tables, no bold formatting, no clean/passing file lists.

Finding granularity: WHAT principle is violated + approximate scope (line count).
Exclude: line numbers (stale on edit), implementation recommendations.
C1-SIZE findings: include size remediation classification from scout (trim/split/compress + rationale).

---

## PRD Document Format

<!-- Referenced by: apex-apex.md Step 2.6 (prd-document creation) -->

YAML front matter:

```yaml
name: prd-<short-title>-<uid>
created: <today>
updated: <today>
implemented_items:
  must_have: []
  should_have: []
  nice_to_have: []
progress:
  must_have: { total: N }
  should_have: { total: N }
  nice_to_have: { total: N }
```

`implemented_items` tracks REQ-IDs per tier. Remaining per tier: `total - len(implemented_items.{tier})`.

Body structure:
- Summary: requirement count and scope (e.g., "15 requirements across 3 areas"). No bold, no bullet lists.
- Per-area requirement sections: one section per functional area, requirements tagged with sequential REQ-IDs (`[REQ-01]`, `[REQ-02]`, ...) globally across the document, each item on its own line.
- Priority ranking: REQ-IDs grouped by Must Have / Should Have / Nice to Have tiers (MoSCoW). No narrative descriptions per tier. When a REQ consolidates findings of mixed severity, the highest severity finding drives the tier (dominant-severity rule).
- No tables, no bold formatting.

Requirement granularity: feature/behavior level (one REQ-ID = one /apex session). Group by dependency chain, not just topic -- items from the same audit area may belong in different session tiers if one is a prerequisite for another. Audit meta-observations (workflow principles, design notes that cannot be directly implemented) must be embedded in tier logic and grouping rationale, not assigned standalone REQ-IDs.
Include: WHAT to build, WHY (user value or technical necessity), cross-REQ dependencies.
Exclude: file paths, implementation strategy, technical details.

---

## Document Mutation Protocol

When marking items as remediated/implemented:

1. Inline marker: Append `[FIXED]` (audit) or `[IMPLEMENTED]` (PRD) to the item line in the document body.
2. YAML update sequence: Before appending, check that the ID is not already present in the target list (because: duplicate IDs cause incorrect progress tracking and may trigger premature completion gate). Append the ID to `fixed_items.{tier}` (or `implemented_items.{tier}`) only if absent. Update `updated` date.
3. Tier resolution: The ID's tier is determined by its placement under the priority-ranking section in the document body.
4. Completion gate: If all tiers have `len(fixed_items.{tier}) == total` (or `len(implemented_items.{tier}) == total`), delete the file. Otherwise print remaining count per tier.
5. Cross-reference rule: Verification fixes (VERIFY FIXES from apex-verify) matching pending items by file and violation get the same `[FIXED]`/`[IMPLEMENTED]` treatment.

---

## Matrix Mutation Protocol

When marking audit-matrix cells as remediated:

1. For each completed cell key (`target:criterion`), set `status` from `fail` to `remediated` and set `remediated_at` to ISO 8601 timestamp. Count the number of cells actually matched and updated.
2. **Match verification (safety gate):** If zero cells were matched from the provided cell keys, this is a key-matching error -- print `MATRIX ERROR: 0/{N} cell keys matched. Aborting mutation.` and stop. Do not proceed to steps 3-6. The file must not be deleted when matching fails.
3. Update the top-level `updated` field to today's date.
4. **Recompute summary.** Count all statuses in the matrix array (including `remediated`). If `pre_filter_na` metadata exists in the JSON, add its `count` to the `not_applicable` total and to `total_cells`. Update `data['summary']` with the recomputed values. Use inline Python or `compute_summary()` from `audit_matrix_lib.py`.
5. **Sync persistent verdicts.** Derive theme from `data['theme']` and project root from `data['project_root']`. Write all non-`unchecked` cells from the matrix to `{project_root}/.claude/audit-verdicts/{theme}-verdicts.json` with format: `{"version": "1.0", "theme": ..., "catalog_path": ..., "updated": ..., "cells": [...]}`.
6. **Completion gate:** If all cells with `status` not in (`pass`, `not_applicable`) are now `remediated`, delete the matrix file and print: "Audit matrix fully remediated."

---

## Audit Input Trust

**Attribution caveat.** Audit document file attributions and data-flow assertions are hypotheses, not ground truth -- the audit author may have attributed a bug to the wrong file or asserted an incorrect data-flow path. Treat the audit's file references as starting points for scout verification, not as the definitive modification list.

**Trust calibration.** When the task input is an audit document (audit-remediation, security audit), treat file attributions and data-flow assertions as approximate hypotheses, not facts. File attributions may reference wrong targets; data-flow claims (e.g., "frontend reads from X", "service Y calls Z") may reflect stale or incorrect understanding. Disconfirmation checks at scan depth cannot verify data-flow claims -- they require source-level tracing. Forward file attribution uncertainty and data-flow claims to scouts for verification. When scouts reveal different target files or data flows than the audit describes, trust scout findings over audit assertions.
