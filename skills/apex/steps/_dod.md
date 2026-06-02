# apex Workstream-B definition-of-done

Acceptance checklist for the apex context-rot structural split (Workstream B) and
its prerequisites. Relocated from the apex-context-rot-optimization plan
(item-5 deliverable 1) to its post-B home.

`skills/apex/steps/` now holds all 15 lazy-loaded step contracts (`01-analyze.md` ...
`15-summary.md`; B step-2 extraction complete - runs 74cb182f / 9101979a / c982c195).
The item-3 step-read gate (`step-read-gate-hook.sh`) is wired LIVE and ARMED (the
`{session}-step-progress.json` sentinel is created at every session mint). The ENFORCEMENT
half is now WIRED: `skills/apex/SKILL.md` "Per-step dispatch" emits
`TaskUpdate(status=in_progress, metadata={step: N})` before each step's contract Read, so
`active_step` advances and the gate enforces read-before-work for every real /apex session.
What stays LIVE-RUN-GATED is the empirical sign-off, not the wiring: R3-a perf on the hot
Bash/Task path and a no-false-denies real-transcript canary, both measurable only from a
captured standard run (no standard run is producible inside an admin-apex session).

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
| 8 Execute | `steps/08-execute.md` | 4500 (absorbed execute.md) |
| 2-4, 7, 9-15 | `steps/NN-*.md` | 2500 (default) |

Step 8 absorbed `execute.md` (tier 4500); step 10 absorbed `review.md` (10.5) into
`steps/10-verify.md` (default 2500 tier).

## A-core (met)

- admin-apex audit reads hash-roster=0 across all runtime-loaded docs.
- Per-file word deltas match the recorded strip savings.
- No broken cluster -> git-history mapping.

## B (the structural split)

Acceptance status re-verified VERSION 8.0.x (admin-apex run 3ddb1e42, mechanical pass):

- MET - every `steps/NN-*.md` is `<=` its content-budget tier (audit-enforced via the
  inventory `steps/` glob; densest is `08-execute.md` at 91% of its 4500 tier).
- MET - `skills/apex/SKILL.md` skeleton is `<=` ~1.5k words (1357w).
- MET - `test-step-gate.sh` (item-3 step-read gate) green (11/11).
- PARTIAL - `transcript-step-read-check.py` (item-5 canary) green over the 8/8 synthetic
  fixtures (`test-transcript-step-read.sh`). A green over a REAL captured /apex
  standard-run transcript with a live `steps/NN` gates spec is LIVE-RUN-GATED: with the
  ENFORCEMENT wiring above, real /apex runs now emit the per-step `metadata.step` boundary,
  so a real fixture becomes capturable on the next standard run - none has been captured
  inside this admin-apex session yet.
- LIVE-RUN-GATED - pre/post-B token accounting (R1) recorded for a standard run, so an
  equal or higher total reads as the expected recency tradeoff, not a regression.

The mechanical split (skeleton + 15 lazy-load step files + armed gate + synthetic canary)
plus the ENFORCEMENT wiring (orchestrator emits `metadata.step`) is structurally COMPLETE.
The remaining items are empirical captures that require a real /apex standard run, which
cannot be produced inside an admin-apex session; the major-bump step-6 ACCEPTANCE sign-off
lands once they are captured from a live run.

## apex-merge (item 4)

- `resolve-one-conflict.md` exists; `SKILL.md` Step 4 is skeleton-only.
- The synthetic 2-conflict-file fixture shows the reload reminder emitted twice.
