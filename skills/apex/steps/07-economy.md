# apex step 7 - Economy pre-flight

Lazy-loaded contract for orchestrator step 7. Dispatched from `skills/apex/SKILL.md`
step 7; Read this file before executing the step so the rule is maximally recent
(B/R3 read-before-work). The item-3 step-read gate enforces the read once armed;
until then the dispatch is a soft convention. This file is the full per-step contract. Cross-cutting rules: `apex-core.md` ## Conventions; routing summary: `apex-core-overview.md`.

## Contract

Inline **deterministic rule** (no AI emit, no subagent). Inputs: `{session}-hypothesis.json` (`goals`), `{session}-main-scope.json` (`allowed_files`).
   ```
   tier = "economy" if (
     (
       len(hypothesis.goals) == 1
       AND len(allowed_files) <= 5
       AND no /\b(rewrite|migrate|redesign|new endpoint|new component)\b/i match in any goals[]
     )
     OR
     (
       # Single-plan-file multi-phase exception: a continue:<plan-file> prompt
       # whose goals[] all reference the same plan-file coordinate (the plan
       # path appears in every goal entry, or the goals are the plan's phase
       # headings emitted verbatim) and no goal matches a rewrite/refactor/
       # migrate/new-endpoint verb is one atomic feature execution, not N
       # independent tasks - len(goals)-driven standard tier is misapplied
       # (9-goal single-plan-file tightly-coupled multi-
       # phase plan tripped standard tier; all 9 goals formed one atomic
       # B1 exception).
       all goals[] reference one shared plan-file coordinate
       AND no /\b(rewrite|refactor|migrate|redesign|new endpoint|new component)\b/i match in any goals[]
     )
     OR
     (
       # Pure-audit / report-only exception: report-only mode - or every goal a
       # verify/check/audit predicate with no write target - is a read-only
       # fan-out where Sonnet suffices and the polish/learn skip is correct, so
       # goals.length is irrelevant (multi-
       # goal all-green audits burned 88k-109k tokens on standard/opus for
       # checklist passes; steps/08-execute.md B3 already clusters such fan-outs under E1).
       hypothesis.mode == "report-only"
       OR every goals[] entry is a verify/check/audit predicate with no write target
     )
   ) else "standard"
   ```
   Reason string: `"len(goals)=N, allowed_files=M, rewrite_match=<true|false>, single_plan_file=<true|false>, report_only=<true|false>"` (mechanical; reproducible run-to-run). `rewrite_match` is the literal `/\b(rewrite|migrate|redesign|new endpoint|new component)\b/i` regex from the economy gate above - word-boundary match against any `goals[]` entry; substring-of-token matches do NOT set rewrite_match=true (rewrite_match=true logged when no goal text carried a gated verb). Write `{session}-tier.json`; producer-validate via `bash skills/apex/scripts/validate-json.sh tier.schema.json <path>`. Drives step 8 executor model + step 11 learn skip. Same prompt + scope -> same tier, every run.
