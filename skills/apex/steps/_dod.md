# apex Workstream-B definition-of-done

Acceptance checklist for the apex context-rot structural split (Workstream B) and
its prerequisites. Relocated from the apex-context-rot-optimization plan
(item-5 deliverable 1) to its post-B home.

This file also establishes `skills/apex/steps/` - the directory that will hold one
lazy-loaded contract per orchestrator step once extraction (B step 2) lands. Until
then only this checklist lives here; no step contract has been extracted yet, so the
item-3 step-read gate (`step-read-gate-hook.sh`) finds no `steps/NN-*.md` to gate and
fail-opens on every work tool.

## Canonical step filenames

Extraction MUST use these exact names so the `content-budget.json` per-step tiers
match (`cap_for` keys on the exact path). Hot steps carry explicit higher tiers; all
other steps inherit the 2500-word default. The item-3 hook's `steps/0*(\d+)-...md`
regex also keys on the zero-padded leading step number.

| Step | File | Tier |
|------|------|------|
| 1 Analyze | `steps/01-analyze.md` | 3500 |
| 5 Load lessons | `steps/05-lessons.md` | 3000 |
| 6 Discovery | `steps/06-discovery.md` | 3500 |
| 8 Execute | `steps/08-execute.md` | 4000 (absorbs execute.md) |
| 2-4, 7, 9-15 | `steps/NN-*.md` | 2500 (default) |

Step 8 absorbs `execute.md`; step 10 absorbs `review.md` (10.5).

## A-core (met)

- admin-apex audit reads hash-roster=0 across all runtime-loaded docs.
- Per-file word deltas match the recorded strip savings.
- No broken cluster -> git-history mapping.

## B (the structural split)

- Every `steps/NN-*.md` is `<=` its content-budget tier.
- `skills/apex/SKILL.md` skeleton is `<=` ~1.5k words.
- `test-step-gate.sh` (item-3 step-read gate) green.
- `transcript-step-read-check.py` (item-5 canary) green over a captured /apex
  standard-run transcript with a real `steps/NN` gates spec - read-before-work
  asserted per step from the session JSONL.
- Pre/post-B token accounting (R1) recorded for a standard run, so an equal or
  higher total reads as the expected recency tradeoff, not a regression.

## apex-merge (item 4)

- `resolve-one-conflict.md` exists; `SKILL.md` Step 4 is skeleton-only.
- The synthetic 2-conflict-file fixture shows the reload reminder emitted twice.
