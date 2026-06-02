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
The empirical sign-off is now CAPTURED (admin-apex run 5aac207a): a real headless
standard-tier /apex run was driven in a throwaway scratch repo (`claude -p "/apex ..."`
subprocess) and its session transcript replayed through the read-before-work canary -
GREEN, steps 1-13+15 PASS (14 correctly skipped on the non-trivial path), 0 violations
across 15 gates; the live `step-read-gate-hook.sh` was armed + tracking and never falsely
denied (the orchestrator complied every step). R3-a perf and pre/post-B token accounting
were measured from that run (see `## B`). "Capturing a standard run" needs only a nested
`/apex` subprocess, not an in-session /apex - the prior "not producible inside an
admin-apex session" framing conflated *driving* a run with *capturing* one.

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
- MET - `skills/apex/SKILL.md` skeleton is `<=` ~1.5k words (1533w; grew from 1357w when the
  ENFORCEMENT "Per-step dispatch" + "Cross-step invariants" sections landed - still far under
  the 2500 default budget).
- MET - `test-step-gate.sh` (item-3 step-read gate) green (11/11).
- MET - `transcript-step-read-check.py` (item-5 canary) green over BOTH the 8/8 synthetic
  fixtures (`test-transcript-step-read.sh`) AND a real captured standard-run transcript (run
  5aac207a): steps 1-13+15 all PASS read-before-work, 0 violations / 15 gates. The real run is
  committed as `skills/apex/scripts/fixtures/apex-step-read-fixture.jsonl` (orchestrator
  tool_use events, home paths normalized to /repo) and re-asserted every suite run via
  `replay-canary.sh` + `test-replay-acceptance.sh` (suite item 21). The canonical 15-gate spec
  is `skills/apex/scripts/step-gates.json` (boundary = `metadata.step`).
- MET - R3-a perf measured (`bench-step-gate.sh`, 200 iters): ~40 ms/work-tool while ARMED
  (python spawn dominates) / ~4.8 ms non-apex fast-path (no python). The armed cost is paid per
  Bash/Task/Edit during a real /apex run - bounded, acceptable, re-measurable after any hook edit.
- MET - pre/post-B token accounting (R1) recorded from run 5aac207a: the always-resident
  orchestrator-contract floor fell 6622w monolith -> 1533w skeleton (-77%); the full 11483w step
  corpus is read lazily (never all resident; peak run context 82.4k tok), and the run generated
  49.3k output tok. The higher total contract-READ volume is the designed recency tradeoff (each
  step's contract is freshly read at its step), not a regression - the persistent context floor
  dropped 77%.

The mechanical split (skeleton + 15 lazy-load step files + armed gate + synthetic canary), the
ENFORCEMENT wiring (orchestrator emits `metadata.step`), AND the empirical sign-off (real-run
canary green + R3-a + token accounting) are all COMPLETE. The major-bump step-6 ACCEPTANCE is
SIGNED OFF at VERSION 10.0.0 (admin-apex run 5aac207a). Workstream B is done.

## apex-merge (item 4)

- `resolve-one-conflict.md` exists; `SKILL.md` Step 4 is skeleton-only.
- The synthetic 2-conflict-file fixture shows the reload reminder emitted twice.
