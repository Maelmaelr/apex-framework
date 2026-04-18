# apex-apex - Plan and Delegate Path

<!-- Called by: SKILL.md Step 5B (complex tasks requiring planning) -->

This workflow scouts the codebase (if needed), greps relevant lessons, synthesizes findings into a high-level plan, and uses EnterPlanMode so context clears before implementation.

## Step 2: Scout Phase

Read and follow ~/.claude/skills/apex/apex-scout.md.
Pass: preliminary file list from SKILL.md Step 2 scan, project-context.md reference. If the task description explicitly mentions "audit", pass the `audit` hint so scout enters audit mode directly.

**Document-input check.** Before launching apex-scout.md: if the task argument is a file path to an existing `.claude-tmp/{audit,prd}/*.md` document, read it. If the document contains structured findings (numbered items with severity/priority), print `DOCUMENT INPUT: {path} -- {N} items, skipping scout` and proceed directly to Step 2.6a with the document as scout-equivalent input. This does not apply to partial/incomplete documents or bare task descriptions.

**Scout findings reuse procedure.** Before launching apex-scout.md:
1. Glob for `.claude-tmp/scout/scout-findings-*.md` with today's date prefix (YYYYMMDD). If none exist: skip reuse, proceed with apex-scout.md.
2. If concurrent session manifests were detected in Step 0: skip reuse (concurrent sessions may contaminate shared findings).
3. Read the file. Determine concern type (feature, audit, refactor). If unclear: skip reuse, proceed with apex-scout.md.
4. Assess coverage: if findings cover <80% of preliminary file list files: skip reuse.
5. For audit-type findings: spot-check 2-3 representative FAIL patterns via Grep. If >50% already resolved in code: skip reuse (stale findings).
6. All checks pass: print `SCOUT REUSE: {file} covers current scope -- skipping fresh scouts`. Use the existing file path for the Step 2.6 gate.

After apex-scout.md completes, it returns a scout findings file path (`.claude-tmp/scout/scout-findings-{uid}.md`). **Gate:** Verify scout findings exist (Glob or Read the path). If reusing existing findings, verify the file's date prefix matches today (YYYYMMDD). If running fresh scouts and no findings file exists, you skipped apex-scout.md Step 6 (exploration) or Step 8 (audit) -- go back and write it before proceeding. Keep this path for Step 6 (plan Context and Required Reading). Exception: if scout returned skip (recommendation=null), quick-scope (recommendation=downgrade), or question-answered (recommendation=question-answered), skip this findings file-existence gate and proceed directly to Step 2.6.

Update manifest with scout findings path: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} scout_findings={scout-findings-path}` (best-effort -- do not retry on failure)

**Cross-session dedup.** After writing findings, run: `python3 ~/.claude/skills/apex/scripts/scout-dedup.py --theme {task-theme} --findings-file {scout-findings-path}`. Print the delta report. If converged (exit code 1): print convergence message. This applies even when the main agent (not a scout subagent) persists findings during parallel-scout orchestration.

**Scout-to-plan checkpoint.** Before writing the plan, verify 2 scout assumptions: (1) re-Grep one finding's key evidence reference (file + pattern) to confirm it still holds (catches stale findings from long scout runs), (2) if scouts discovered files not in the original modification list, Glob-verify they exist. If verification fails, note the discrepancy in the plan's Context section. Budget: max 2 search calls.

**Early scope signal.** If scout findings indicate output is a single document with <=5 source files, print `EARLY SCOPE SIGNAL: single-document, {N} source files` -- this feeds into Step 2.6 downgrade evaluation.

Continue to Step 2.6.

## Step 2.6: Re-evaluate Path (MANDATORY GATE)

**MANDATORY:** After resolving scout findings, you MUST explicitly evaluate and print your path decision before proceeding. Do not proceed past this step without printing one of the three outcomes below.

<!-- Design: Audit discovery (produce document) is decoupled from remediation (fix items). Scout auto-detects audit-shaped findings. Subsequent /apex <audit-file> sessions pick up batches incrementally. -->

**If scout returned recommendation=`question-answered`:** Print the answer summary from scout. Clean up session artifacts: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id}` (Bash). Print `APEX completed. 0 files changed (read-only verification).` and STOP. No plan, no tail, no reflection -- the session produced no changes.

**If scout returned `skip` (recommendation=null):** No scout findings produced. Evaluate against SKILL.md Step 3 Path 1 criteria below (scout found nothing worth reporting -- task may be simpler than expected).

**If scout returned `plan-input` (recommendation='plan-input'):** Scout produced findings for plan writing. Proceed to the downgrade evaluation below, then to Step 3.5 if continuing Path 2. **Auto-remediation rule:** When `plan-input` findings contain FAIL items, remediation is the automatic next step -- evaluate the path decision below and continue to implementation (Path 1 downgrade or Path 2 plan) without pausing. Do not present FAIL findings as final session output, summarize the audit as "complete," or wait for user confirmation before proceeding. The report-and-stop path is exclusively `audit-document` output (Step 2.6a). If interrupted by the user mid-step, resume Step 2.6 evaluation from the path decision.

**If scout recommends `audit-document` output OR task explicitly requests document creation (PRD, spec, requirements):** Continue to Step 2.6a.

Evaluate against SKILL.md Step 3 Path 1 criteria.

**Single-teammate heuristic.** If the resolved scope would produce only one teammate (all files in a single package boundary with <=5 files AND no file in the modification list exceeds the CLAUDE.md split-first threshold (>400 lines)), MUST downgrade to Path 1 unless the teammate specifically needs agent-team features (lead relay for user decisions, cross-dependency messaging with other parallel work). Concrete criteria: the task requires user decisions mid-implementation (lead relay), OR has declared cross-dependencies with other parallel work already in flight. "The scope is complex" is not sufficient justification.

**Downgrade (all criteria met):** Print "Scouts indicate simpler scope than expected. Downgrading to Path 1 (Direct)." (no "PATH DECISION:" prefix -- that belongs to SKILL.md Step 3). Update manifest to record downgrade: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} path=1-downgraded current_step=5A` (best-effort -- do not retry on failure). Complete Step 3.5, then exit apex-apex.md entirely -- return to SKILL.md Step 5A. Hard exit: no further apex-apex step labels after downgrade.

**Continue Path 2 (any criterion not met):** Print "Continuing Path 2." If the scout returned quick-scope (`recommendation='downgrade'`) but Path 1 criteria are not met, scout findings are absent -- re-run apex-scout.md from Step 2 (Identify Exploration Areas) with the quick-scope file list to produce findings before plan writing. **Loop-break guard:** pass `quick-scope-rejected: true` to the re-run scout; the scout MUST skip its Step 1 quick-scope return path (no second `downgrade`) and proceed directly to Step 2 area identification regardless of file count. Max 1 re-run -- if the re-scout also returns without findings, accept the quick-scope file list as-is and proceed to plan writing with Context noting "findings file skipped (quick-scope re-scout unproductive)". Print: `QUICK-SCOPE FALLBACK: re-scouting -- downgrade rejected, findings needed for plan.` Proceed to Step 3.5 after scout findings are persisted.

## Step 2.6a: Document Output Handler

Determine output type -- audit document or PRD document:
- If task description explicitly requests PRD (e.g., "create a prd", "write a PRD", "product requirements", "spec out", "requirements document"): set output type to `prd-document`. This applies regardless of whether scout ran, was skipped, or recommended `plan-input` -- explicit PRD intent overrides scout recommendation.
- If task description clearly implies audit/verification/compliance/fixing: set output type to `audit-document`.
- Otherwise: use AskUserQuestion with options: "Audit document" (description: "Findings to fix -- tracks violations with BP-IDs, remediated incrementally via /apex <audit-file>") vs "PRD document" (description: "Requirements to implement -- tracks features with REQ-IDs, implemented incrementally via /apex <prd-file>").

Type-specific substitutions:

1. `audit-document` -- type name: audit, subdirectory: `.claude-tmp/audit/`, filename prefix: `audit-`, print label: "Scout recommends audit document. Writing audit file."
2. `prd-document` -- type name: PRD, subdirectory: `.claude-tmp/prd/`, filename prefix: `prd-`, print label: "Writing PRD document."

1. Print the label for the resolved output type (see reference above).
1a. Update session manifest so concurrency-advisory reflects the document-output flow: `bash ~/.claude/skills/apex/scripts/update-manifest.sh {session-id} path=document-output current_step=2.6a` (best-effort -- do not retry on failure).
2. Create the subdirectory if it does not exist.
3. Derive a short title from the scope (2-3 words, kebab-case, e.g., `doc-bloat`, `auth-security` for audit; `canvas-gen`, `credit-system` for PRD). Generate a unique ID via Bash: `echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`. Write the document to `{subdirectory}{prefix}<short-title>-<uid>.md`. For `audit-document`: follow the "Audit Document Format" spec in ~/.claude/skills/apex/apex-doc-formats.md. For `prd-document`: transform scout findings into high-level actionable requirements -- consolidate granular findings into feature/behavior-level items (each a standalone `/apex` session), assign sequential REQ-IDs, classify by MoSCoW priority (Must Have for core/blocking, Should Have for important non-blocking, Nice to Have for polish/optimization); do not prescribe file paths or implementation details. Follow the "PRD Document Format" spec in ~/.claude/skills/apex/apex-doc-formats.md.
4. Run structural validation: `python3 ~/.claude/skills/apex/scripts/validate-document.py {document-path}`. If validation fails, fix the reported errors before continuing.
5. Print: "{Type name} document written to {subdirectory}{prefix}<short-title>-<uid>.md" (using actual values).
Steps 3.5 and 4.6 do not apply for document output. Proceed with steps 6a-6b below:
6a. Continue to Step 4.5 (Pre-Plan Reflection).
6b. After reflection, run tail in lessons-only mode: read and follow ~/.claude/skills/apex/apex-tail.md, requesting lessons-only (document session discovers patterns worth capturing as lessons; no code changed so diff/verification/doc-update are unnecessary). Clean up session artifacts: `bash ~/.claude/skills/apex/scripts/cleanup-session.sh {session-id}` (Bash). Then print "APEX completed." and STOP.

## Step 3.5: Load Lessons

Follow SKILL.md Step 3.5 lesson loading procedure (uses `~/.claude/skills/apex/scripts/grep-lessons.sh`).

1. **Select terms (6-8 total).** Sources: scan results, scout findings. Replace generic scan terms with specific scout-discovered terms (table names, service names, function names) -- do not stack all sources. Domain filter: when scout findings are clearly single-domain (backend service helpers, API controllers, DB migrations), omit terms that primarily surface lessons from the other domain (frontend hook patterns, component lifecycle, UI state) -- cross-domain lessons add context noise without aiding the fix. Broad framework/domain tokens (e.g., `canvas`, `react`, `upload`, `connected`, `upstream`, `hook`, `indicator`) function as generically as blocklisted terms -- cap at 1 per query. Accept term count below 6-8 when only a few specific symbols are available; undersized queries beat padded ones.
2. **Run grep-lessons.sh.** If output is useful (<150 lines, non-empty), proceed to hit-tracking (SKILL.md Step 3.5 sub-step 3).
3. **Retry rules (scoped by output).**
   - **Truncated (>150 lines):** drop the 1-2 most generic terms and retry once. Do not replace with more specific symbols -- narrow terms tend to match nothing. Skip after the retry regardless of output. **2 total attempts is the hard cap and applies only to this case.**
   - **Empty (0 matches):** skip immediately after the first attempt. Do NOT retry with fewer/different terms. `grep-lessons.sh` uses case-insensitive OR matching, so fewer terms only narrows results -- retrying cannot widen an empty match set.
   - Never retry with `head`, alternate keywords, or any other workaround outside the truncated-retry path above.

Keep loaded lessons in context for plan writing (Path 2) or subagent prompts (downgrade to Path 1).

## Step 4.5: Pre-Plan Reflection (MANDATORY)

**MANDATORY:** This is a distinct step from Step 4.6 -- do not conflate or label them together. Read and follow ~/.claude/skills/apex/apex-reflect.md with mode: `discovery`. This captures discovery-phase workflow observations before context clears at plan approval.

**Gate:** Before proceeding to Step 4.6, one of reflect's Step 5 prints must appear in output: `Reflect: {count} workflow observations captured ({categories})` or `Reflect: No workflow observations`. Absence of that line means Step 4.5 was skipped -- return to it before moving on.

## Step 4.6: Effort Assessment

Follow effort assessment procedure (`effort-trigger.txt`) against the plan's scope.

## Step 5: Enter Plan Mode

<!-- Dependency: Claude Code v2.1.81+ hides "clear context" on plan approval by default.
     APEX Path 2 requires context clearing at plan approval (the plan's Instructions section
     is the sole context bridge to implementation). Setting "showClearContextOnPlanAccept": true
     in ~/.claude/settings.json restores the option. Without it, discovery context bleeds into
     implementation, degrading plan adherence and wasting tokens. -->

Call EnterPlanMode. If EnterPlanMode fails, report the error to the user and stop -- do not proceed to plan writing. Do NOT write the plan to any intermediate file. The plan mode system provides a designated file path.

## Step 6: Write High-Level Plan

<!-- Design: Plans are goals + required reading + verification. NO implementation steps. Teammates figure out "how" from docs. -->

Read and follow ~/.claude/skills/apex/apex-plan-template.md. Pass: scout findings file path, session type, session-id from Step 0, task type from Step 1, scan/scout terms for lesson loading context. The template contains the plan format, writing guidance, validation checklist, and ExitPlanMode instructions.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Skip EnterPlanMode or ExitPlanMode (except via Step 2.6 sanctioned downgrade to Path 1, which still requires Step 3.5 before returning to SKILL.md, or audit/PRD-document output (Step 2.6a, which stops after reflection and lessons-only tail))
- Implement before plan approval
- Write implementation details in the plan (plans are goals + docs, not steps)
- Omit required reading from Goals (teammates need doc pointers)
- Assign overlapping file ownership (each file = one teammate)
- Skip scouting when patterns are unclear (apex-scout.md enforces this)
- Scout when docs/examples are sufficient (apex-scout.md enforces this)
- Include unverified scout findings (counts, existence, absence) -- apex-scout.md handles verification
- Inline scout logic in this file -- all scout behavior lives in apex-scout.md
- Implement directly after scouts without formally executing Step 2.6 (re-evaluate path). Every scout phase MUST end with either an explicit downgrade message (Step 2.6) or "Continuing Path 2" before proceeding. Silent transitions to implementation are forbidden.
- Omit shared interface contracts (API endpoints, route paths) when plan involves agents that must agree on cross-package interfaces
- Write the plan to an intermediate file before entering plan mode (e.g., `.claude-tmp/apex-plan.md`). The plan mode system provides a designated file path.
- Print or re-execute apex-apex step labels (Step 2.6, etc.) after a Step 2.6 downgrade to Path 1 (exception: Step 3.5 is part of the downgrade exit sequence and must be executed). The downgrade is a hard exit from apex-apex.md -- all subsequent steps follow SKILL.md numbering.
- Re-read files in plan mode that scouts already analyzed in full. Use scout findings directly to write the plan. Only read a scouted file if you need specific content not covered by scout reports (e.g., exact text to quote in acceptance criteria that scouts did not include). Spawning Explore agents, general-purpose exploration/design subagents, or any delegation subagents in plan mode is prohibited -- plan writing is inline synthesis from scout findings + targeted Read/Grep for specific missing details.
- Proceed to Step 2.6 without completing all steps of apex-scout.md, including scout verification (Step 4 in exploration, Steps 4-5 in audit) AND findings persistence (Step 6 in exploration, Step 8 in audit). Scouts returning results is not the same as the scout phase completing -- verification and file write must both happen in the main context before proceeding.
- Embed full scout findings in the plan Context section instead of referencing the scout findings file. Context gets a 2-3 line summary; teammates read the file via Required Reading. If no file exists, the file write step was skipped -- go back and write it.
- Present scout audit FAIL findings as final session output when recommendation is `plan-input` (because: FAIL items are implementation tasks, not a report to deliver -- the report-and-stop path is exclusively Step 2.6a `audit-document` output. Presenting findings as "audit complete" caused a user to manually prompt remediation that should have been automatic)
