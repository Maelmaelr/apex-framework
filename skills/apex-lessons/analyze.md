# apex-lessons: Analyze Phase

Called from `SKILL.md` Step 2 (after the extract phase). Returns to `SKILL.md` for the final report.

Keeps `.claude/lessons.md` lean: deduplicates, freshness-checks, **drops obvious lessons**, then routes survivors to their best permanent home. Self-reflects at end via `agents/reflector.md` so signals feed `/apex-improve`.

Project-scoped run state at `.claude-tmp/lessons-analyze-active/` (NOT `~/.claude/.claude-tmp/`; analyze operates on the project's `.claude/lessons.md` so its run state lives with the project root). Per-task summary trace at `{run}-summary.md` (read by reflector). All artifacts swept by Reflect + Cleanup phase (post-success) or by SessionEnd hook on hard-stop.

## Determinism / non-determinism mix

Mirrors apex hot path discipline: deterministic pre-scan -> LLM judgment -> deterministic write.

| Phase | Deterministic | Non-deterministic |
|-------|---------------|-------------------|
| Consolidate | `lesson-dedup.py` similarity pairs, grep promoted refs | merge / dedup / promote decisions |
| Triage + Filter | `stale-lessons.py` last-hit threshold, Glob/Grep refs | **non-obvious classification** (lessons.md must be lean) |
| Clean | section/entry length thresholds | merge target choice, condense rewriting |
| Route + Finalize | grep target-files + rule `paths:` globs for anti-duplicate | target routing (incl. `.claude/rules/` graduation), anti-pattern phrasing |
| Reflect + Cleanup | `append-with-lock.sh`, `cleanup-run.sh` | gap / improvement extraction (Sonnet reflector) |

## Task Setup

**Step 0a: Mint run + manifest** (always; both modes).

```
RUN=$(bash skills/apex-lessons/scripts/init-run.sh --phase analyze)
```

Echoes 8-hex `RUN` to stdout. Writes manifest at `.claude-tmp/lessons-analyze-active/{RUN}.json` (`{run, cc_session_id, pid, producer:"lessons-analyze"}`). Capture `RUN` and use throughout.

**Step 0b: Pipeline mode gate** - criteria below, but executed by `consolidate.md` Step 1, not this dispatcher: counting total/unverified lessons requires reading `.claude/lessons.md`, which only the Consolidate phase does, so the gate decision (and the conditional TaskCreate) lives there. Listed here for the Task Setup contract.

- **Simplified mode** (total < 10 AND unverified < 5): Skip TaskCreate; run phases inline. Reflect + Cleanup still fires.
- **Full mode** (all other cases): TaskCreate the 5-task chain below; mark each task in_progress when entering and completed when exiting.

```
1. Consolidate            (consolidate.md)                  blockedBy: -
2. Triage + Filter        (triage.md)                       blockedBy: 1
3. Clean                  (triage.md)                       blockedBy: 2
4. Route + Finalize       (route.md)                        blockedBy: 3
5. Reflect + Cleanup      (reflect.md)                      blockedBy: 4
```

Reflect + Cleanup ALWAYS runs (even on early exits) so friction signals are not dropped.

## Phase dispatch

| Phase | Sub-file | Owns |
|-------|----------|------|
| Consolidate (Steps 1, 2, 2.5) | `consolidate.md` | dedup-script + LLM merge, promoted-entry detection |
| Triage + Filter (Steps 3, 3.5, 3.7, 4) | `triage.md` | freshness, archive, **non-obvious filter**, unverified routing gate |
| Clean (Step 4.5) | `triage.md` | small-section merge, condense, oversized split |
| Route + Finalize (Steps 5, 6, 6.5, 7, 8, 9) | `route.md` | route, verify-write, regenerate index, report |
| Reflect + Cleanup (Step 10) | `reflect.md` | reflector spawn (`--phase lessons-analyze`), `cleanup-run.sh --phase analyze --run {run} --post-success` |

Sub-file early exits jump to Reflect + Cleanup with the exit reason captured in `{run}-summary.md` (the early-exit IS the gap signal worth reflecting on):
- `consolidate.md` Step 1 "no lessons" -> Reflect + Cleanup
- `triage.md` Step 3.5 zero-remaining -> write + index, then Reflect + Cleanup
- `triage.md` Step 3.7 zero-after-filter -> write + index, then Reflect + Cleanup
- `triage.md` Step 4 all-verified -> Clean still runs, Route is skipped, then write + index, then Reflect + Cleanup

## Sweep mode (`--sweep`)

Default analyze runs are **incremental**: only lessons touched this run (newly confirmed/promoted, or hit during the Step 3 freshness check) are routing candidates, including `[verified]` lessons eligible for `.claude/rules/` graduation (triage.md Step 4 + route.md Step 6).

`--sweep` (passed by SKILL.md when invoked as `/apex-lessons sweep`) widens the routing pass to the WHOLE verified set in `.claude/lessons.md`: every `[verified]`, path-correlated, terse lesson is evaluated against the `.claude/rules/` `paths:` globs for graduation. Bounded - process in batches, conservative bar (when in doubt, keep). Use it for the first large backlog pass; subsequent normal runs stay incremental.

## Forbidden Actions

Standard apex safety guardrails apply (hook + global-`CLAUDE.md` enforced - no stash, no env-file edits, destructive-op gating, tool-output integrity). Additionally:

- Do not delete lessons without dedup, freshness, OR non-obvious-classification justification
- Do not skip Reflect + Cleanup phase - it always runs (early-exit reasons are gap signals worth reflecting on)
- Do not leave temp files on success - `cleanup-run.sh --phase analyze --run {run} --post-success` removes `.claude-tmp/lessons-analyze-active/{run}-*` (the `--run` flag is required; cleanup-run.sh exits 0 without cleaning if it is absent)
- Do not route verified lessons to skill-file destinations. Verified lessons graduate mainly via the `.claude/rules/` branch (route.md Step 6); route.md also defines two exceptions - reference-grade verified lessons route to docs, and verified `[anti-pattern]` lessons route to CLAUDE.md / docs as warnings/gotchas. Match route.md Step 6; do NOT treat `.claude/rules/` as the sole path
- Do not skip Route on the basis of "extract pre-categorized" / "lessons already well-categorized" rationales. Route skip is permitted ONLY via the deterministic gates: `triage.md` Step 4 (all-verified / zero-routable-unverified) or `triage.md` Step 3.5 / 3.7 zero-after-filter early exits. The extract phase's per-category insertion (Step 2) is NOT a routing claim and never short-circuits analyze.
- Do not accept stale findings from freshness Explore agents without main-context verification (Step 3 post-check verification)
- Do not skip the blockedBy task chain in full mode - all 5 tasks must reach completed status
