# APEX Workflow Audit Criteria Catalog v1.1

## Metadata

- created: 2026-03-31
- updated: 2026-04-13
- criteria-count: 35
- sources: skills/apex/SKILL.md, skills/apex/apex-apex.md, skills/apex/apex-scout.md, skills/apex/apex-tail.md, skills/apex/apex-verify.md, skills/apex/apex-learn.md, skills/apex/apex-reflect.md, skills/apex/apex-team.md, skills/apex/apex-teammate-workflow.md, skills/apex/subagent-delegation.md, skills/apex/apex-plan-template.md, skills/apex/apex-update.md, skills/apex/shared-guardrails.md, skills/apex/apex-doc-formats.md, skills/apex/scripts/, skills/admin-apex/SKILL.md, skills/apex-audit-matrix/SKILL.md, skills/apex-brainstorm/SKILL.md, skills/apex-eod/SKILL.md, skills/apex-file-health/SKILL.md, skills/apex-fix/SKILL.md, skills/apex-git/SKILL.md, skills/apex-init/SKILL.md, skills/apex-lessons-analyze/SKILL.md, skills/apex-lessons-extract/SKILL.md, skills/apex-party/SKILL.md, settings.json, CLAUDE.md
- format: deterministic pre-filters for target-x-criterion matrix generation
- pre-filter-syntax: grep -E (ERE)
- target-syntax: shell glob (compatible with glob.glob() and find)
- project-root: ~/.claude
- scope-note: Criteria verify APEX-internal consistency, threshold alignment, protocol compliance, session management, and cross-file staleness. General skill quality (frontmatter, caller comments, cross-references, script usage docs, etc.) is covered by skill-quality.md -- not duplicated here. Criteria here are complementary and APEX-specific.
- excluded: skills/apex/tests/ (test fixtures), skills/apex/effort-trigger.txt (runtime keyword), skills/apex/apex-scout-audit-checklist.md (runtime-generated checklist), skills/apex-brainstorm/brain-methods.md (static technique catalog), skills/apex-init/context-template.md (project template), skills/apex-party/personas.md (persona definitions)


# Workflow Logic (FLOW)

## FLOW-01: Mandatory gate markers printed at decision points
- description: SKILL.md and apex-apex.md define mandatory gates (path decision, re-evaluation, scan exit) that must print a gate marker before proceeding. Missing gate prints allow silent skips of critical routing logic.
- targets: `skills/apex/SKILL.md`, `skills/apex/apex-apex.md`
- pre-filter: `PATH DECISION:|MANDATORY`
- property: Each mandatory gate has an associated print statement that fires unconditionally before proceeding
- pass: PATH DECISION in SKILL.md Step 3, MANDATORY gate in apex-apex.md Step 2.6 both have unconditional print instructions
- fail: A mandatory gate can be passed without printing its marker
- severity: high
- source: SKILL.md Step 3, apex-apex.md Step 2.6

## FLOW-02: Path 1 criteria use ALL logic, Path 2 criteria use ANY logic
- description: Path routing depends on correct boolean logic -- Path 1 requires ALL conditions true, Path 2 requires ANY condition true. Incorrect logic causes misrouting, wasting sessions on wrong path.
- targets: `skills/apex/SKILL.md`
- pre-filter: `ALL must be true|ANY is true`
- property: Path 1 section states "ALL must be true" and Path 2 section states "ANY is true"
- pass: Both logic keywords present in their respective sections
- fail: Missing or swapped logic keywords
- severity: critical
- source: SKILL.md Step 3

## FLOW-03: Zero-implementation path skips task creation
- description: When no implementation changes are needed (e.g., audit finds zero discrepancies), the workflow must skip task creation and jump to cleanup. Creating empty tasks wastes tokens and produces confusing audit trails.
- targets: `skills/apex/SKILL.md`
- pre-filter: `Zero-implementation|zero-implementation`
- property: Step 5A contains a zero-implementation path that skips to Step 6A sub-step 4
- pass: Zero-implementation shortcut documented with explicit skip destinations
- fail: No zero-implementation path, or path still creates tasks
- severity: medium
- source: SKILL.md Step 5A

## FLOW-04: Replan trigger in Path 1
- description: Path 1 must have an escape hatch to Path 2 when unexpected complexity is discovered mid-implementation. Without it, Path 1 sessions can get stuck on tasks that exceed direct execution capacity.
- targets: `skills/apex/SKILL.md`
- pre-filter: `REPLAN:`
- property: Step 5A contains a REPLAN trigger that re-evaluates against Step 3 criteria
- pass: REPLAN trigger with print format and re-evaluation logic present
- fail: No replan mechanism in Path 1
- severity: high
- source: SKILL.md Step 5A

## FLOW-05: Path 2 handoff is exclusive to apex-apex.md
- description: Step 5B must delegate entirely to apex-apex.md and must not perform any scout, plan, or EnterPlanMode operations directly. Inline Path 2 handling in SKILL.md bypasses scout verification and plan approval.
- targets: `skills/apex/SKILL.md`
- pre-filter: `apex-apex.md`
- property: Step 5B contains only a delegation instruction to apex-apex.md with no inline implementation logic
- pass: Step 5B references apex-apex.md and contains "Mandatory handoff" language
- fail: Step 5B contains inline scout/plan/implementation logic
- severity: high
- source: SKILL.md Step 5B


# Session Management (SESS)

## SESS-01: Session ID format consistency across generators and validators
- description: Session IDs are generated in SKILL.md Step 0 and validated by update-manifest.sh, cleanup-session.sh, and scope-check-hook.sh. Format mismatch between generator and validator causes silent manifest failures.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/update-manifest.sh`, `skills/apex/scripts/cleanup-session.sh`, `skills/apex/scripts/scope-check-hook.sh`
- pre-filter: `apex-.*urandom|apex-\[a-z0-9\]`
- property: Generator produces IDs matching the regex validators expect (^apex-[a-z0-9]{8}$)
- pass: SKILL.md generates 8 lowercase alphanumeric chars; all scripts validate against same 8-char pattern
- fail: Character set mismatch (e.g., generator includes hex but validator expects alphanumeric) or length mismatch
- severity: critical
- source: SKILL.md Step 0, update-manifest.sh, cleanup-session.sh

## SESS-02: Manifest JSON schema matches all consumers
- description: The manifest written in SKILL.md Step 2 must contain all fields read by update-manifest.sh, precompact-apex.sh, and cleanup-session.sh. Missing fields cause silent null reads or script errors.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/update-manifest.sh`, `skills/apex/scripts/precompact-apex.sh`
- pre-filter: `task.*started.*files|manifest`
- property: Every JSON key read by consumer scripts exists in the manifest template written by SKILL.md
- pass: All keys accessed by scripts (task, started, files, path, current_step, tail_mode, scout_findings, decisions) are present in SKILL.md manifest write
- fail: A script reads a key not present in the manifest template
- severity: high
- source: SKILL.md Step 2 (Write session manifest)

## SESS-03: State file lifecycle completeness
- description: Every state file created during a session (manifest, scope.json, budget.json, pre-agent-diff.stat, baseline) must have a corresponding cleanup path. Orphaned state files from crashed sessions accumulate in .claude-tmp/ and trigger false concurrency warnings.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/cleanup-session.sh`, `skills/apex/subagent-delegation.md`
- pre-filter: `scope.json|budget.json|pre-agent-diff|apex-baseline`
- property: Every state file path created by any APEX workflow step is removed by cleanup-session.sh or its creating workflow
- pass: All created state files have cleanup paths (cleanup-session.sh for session artifacts, subagent-delegation.md item 10 for baseline)
- fail: A state file is created but has no cleanup path
- severity: medium
- source: SKILL.md Step 2, subagent-delegation.md item 10, cleanup-session.sh

## SESS-04: Manifest staleness threshold matches script behavior
- description: SKILL.md Step 0 defines a 2-hour staleness threshold for concurrent session manifests. Cleanup logic must use the same threshold. Mismatch causes either premature cleanup (data loss) or stale manifests surviving indefinitely.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/cleanup-session.sh`
- pre-filter: `2h|>2h|stale`
- property: SKILL.md's "delete if >2h old" matches cleanup script's age-based deletion threshold
- pass: Both use 2-hour (or equivalent) staleness threshold
- fail: Thresholds differ between SKILL.md and cleanup behavior
- severity: medium
- source: SKILL.md Step 0


# Threshold Consistency (THRESH)

## THRESH-01: Scan budget numbers match between SKILL.md and hook script
- description: SKILL.md Step 2 defines hard limits of 5 Grep/Glob calls and 3 doc-read calls. The scan-budget-hook.sh enforces these limits via PostToolUse hooks. Mismatched numbers cause either premature budget exhaustion or unenforced limits.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/scan-budget-hook.sh`
- pre-filter: `5.*search|5.*Grep|max.*5|grep_glob_count`
- property: The budget numbers in SKILL.md Step 2 (5 search, 3 doc-read) match the max values in scan-budget-hook.sh
- pass: Both sources define identical budget limits
- fail: Budget limits differ between documentation and enforcement
- severity: high
- source: SKILL.md Step 2, scan-budget-hook.sh

## THRESH-02: File health thresholds consistent across all sources
- description: File health gates use 400 lines (split-first) and 500 lines (blocked) thresholds. These appear in SKILL.md Step 2, CLAUDE.md Code Quality, apex-verify.md Step 3.8, file-health-check.sh, and apex-teammate-workflow.md. All must agree.
- targets: `skills/apex/SKILL.md`, `CLAUDE.md`, `skills/apex/apex-verify.md`, `skills/apex/scripts/file-health-check.sh`, `skills/apex/apex-teammate-workflow.md`
- pre-filter: `400|500|BLOCKED_THRESHOLD|split-first`
- property: All five sources define 400 as split-first threshold and 500 as blocked threshold
- pass: 400/500 thresholds identical across all sources
- fail: Any source uses a different threshold value
- severity: high
- source: SKILL.md Step 2, CLAUDE.md Code Quality, apex-verify.md Step 3.8, file-health-check.sh, apex-teammate-workflow.md Phase 2

## THRESH-03: Retry limit consistent across guardrails and verify
- description: shared-guardrails.md defines a retry limit and apex-verify.md uses retry limits for lint and build steps. These must agree. Inconsistency causes either premature failure (too few) or wasted tokens (too many).
- targets: `skills/apex/shared-guardrails.md`, `skills/apex/apex-verify.md`
- pre-filter: `3 attempt|3 retries|up to 3|retry.*3|STUCK`
- property: Retry limits in shared-guardrails match those used in apex-verify.md lint/build retry loops
- pass: Same retry count used in both sources
- fail: Different retry counts or missing STUCK escalation after limit
- severity: medium
- source: shared-guardrails.md rule 8, apex-verify.md Step 2

## THRESH-04: Tail economy detection thresholds documented
- description: detect-tail-mode.sh uses hardcoded thresholds (file count and line count) to determine economy vs full tail mode. These thresholds must be documented in SKILL.md or apex-tail.md so maintainers know what triggers each mode.
- targets: `skills/apex/scripts/detect-tail-mode.sh`, `skills/apex/SKILL.md`, `skills/apex/apex-tail.md`
- pre-filter: `economy|detect-tail-mode|<=5.*files|<=80`
- property: Thresholds in detect-tail-mode.sh are documented in at least one workflow file
- pass: Both the file-count and line-count thresholds appear in SKILL.md or apex-tail.md
- fail: Script uses undocumented thresholds
- severity: medium
- source: detect-tail-mode.sh, SKILL.md Step 6A

# Scout Protocol (SCOUT)

## SCOUT-01: Embedded scout rules version matches header
- description: apex-scout.md defines Core Rules with a version tag (e.g., "Rules v2"). Scout prompt templates embed these rules inline. Version drift between the header and embedded copies causes scouts to follow outdated rules.
- targets: `skills/apex/apex-scout.md`
- pre-filter: `Rules.*v[0-9]|Scout rules.*v`
- property: The version tag in the Core Rules header matches the version tag in both scout prompt templates (exploration and audit)
- pass: All three version references (header, exploration template, audit template) show the same version
- fail: Version mismatch between header and any template
- severity: high
- source: apex-scout.md Core Rules, scout prompt templates

## SCOUT-02: Return schema handler coverage
- description: apex-scout.md defines return types (skip, downgrade, question-answered, plan-input, audit-document). apex-apex.md Step 2.6 must handle every return type. Unhandled return types cause the workflow to proceed without proper routing.
- targets: `skills/apex/apex-scout.md`, `skills/apex/apex-apex.md`
- pre-filter: `recommendation=|question-answered|plan-input|audit-document`
- property: Every return type defined in apex-scout.md Return Schema has a corresponding handler in apex-apex.md Step 2.6
- pass: All five return types (skip, downgrade, question-answered, plan-input, audit-document) have handlers
- fail: A return type exists in the schema but has no handler in Step 2.6
- severity: critical
- source: apex-scout.md Return Schema, apex-apex.md Step 2.6

## SCOUT-03: Audit checklist persisted before scout distribution
- description: In audit mode, Step 1 generates a numbered checklist and must persist it to disk before Step 2 distributes items to scouts. Scouts read the checklist from the file. If persistence is skipped, scouts receive no checklist.
- targets: `skills/apex/apex-scout.md`
- pre-filter: `Persist checklist|audit-checklist`
- property: Step 1 ends with a mandatory file write, and Step 2 references the file path
- pass: Persist step present with "This step is NOT optional" or equivalent emphasis, and Step 2 references checklist-file-path
- fail: No persistence step, or Step 2 does not reference the persisted file
- severity: high
- source: apex-scout.md Audit Mode Steps 1-2

## SCOUT-04: Completeness check covers all verdict types
- description: apex-scout.md Step 4 reconciliation must account for all verdict types (PASS, FAIL, INFO, INCONCLUSIVE, MISSING). Missing verdict types in the completeness format causes undercounting or miscategorization.
- targets: `skills/apex/apex-scout.md`
- pre-filter: `COMPLETENESS:.*PASS.*FAIL|PASS.*FAIL.*INFO`
- property: Step 4 completeness format includes all verdict types
- pass: Format string includes PASS, FAIL, INFO, and MISSING counts
- fail: Any verdict type omitted from the completeness format
- severity: medium
- source: apex-scout.md Step 4


# Delegation Protocol (DELEG)

## DELEG-01: Pre-spawn baseline file path consistency
- description: subagent-delegation.md item 4 creates a baseline at .claude-tmp/pre-agent-diff.stat and item 10 compares against it. Both must use the exact same path. Path mismatch makes scope verification compare against a non-existent file.
- targets: `skills/apex/subagent-delegation.md`
- pre-filter: `pre-agent-diff`
- property: The file path in item 4 (write) matches the file path in item 10 (read and delete)
- pass: Identical path string in both items, including the rm -f cleanup
- fail: Path strings differ between write and read operations
- severity: high
- source: subagent-delegation.md items 4 and 10

## DELEG-02: Small-change inline threshold consistent with callers
- description: subagent-delegation.md defines a <=5 line threshold for inline changes (skip agent spawn). SKILL.md Step 5A references this protocol. The threshold must be the same in both locations.
- targets: `skills/apex/subagent-delegation.md`, `skills/apex/SKILL.md`
- pre-filter: `<=5 lines|small-change|inline`
- property: Threshold value in subagent-delegation.md matches any threshold stated in SKILL.md
- pass: Same line-count threshold in both files
- fail: Different thresholds or SKILL.md overrides without noting the override
- severity: medium
- source: subagent-delegation.md item 3, SKILL.md Step 5A

## DELEG-03: Scope check procedure alignment across callers
- description: Post-subagent scope check is defined in subagent-delegation.md item 10 and referenced by SKILL.md Step 5A, apex-team.md Step 3, and apex-teammate-workflow.md Phase 2. All callers must reference the same procedure and use AskUserQuestion (not auto-revert) for violations.
- targets: `skills/apex/subagent-delegation.md`, `skills/apex/SKILL.md`, `skills/apex/apex-team.md`, `skills/apex/apex-teammate-workflow.md`
- pre-filter: `scope.*check|scope.*violation|Revert.*Keep.*Review`
- property: All callers reference subagent-delegation.md item 10 and use AskUserQuestion for violations
- pass: All callers reference the protocol and none auto-revert
- fail: A caller implements inline scope checking or auto-reverts without user consent
- severity: high
- source: subagent-delegation.md item 10, shared-guardrails rule 5


# Tail Workflow (TAIL)

## TAIL-01: Learn pre-flight conditions match between full and economy tail
- description: apex-tail.md defines three LEARN PRE-FLIGHT conditions (a, b, c) for full tail. Economy tail must evaluate the same three conditions (not a subset). Evaluating different conditions causes inconsistent lesson capture.
- targets: `skills/apex/apex-tail.md`
- pre-filter: `PRE-FLIGHT|LEARN PRE-FLIGHT`
- property: Economy tail section references the same three conditions as full tail
- pass: Both full and economy tail evaluate conditions (a), (b), and (c)
- fail: Economy tail evaluates a different set of conditions
- severity: medium
- source: apex-tail.md

## TAIL-02: Agent 3 session type gates match Session Type Reference
- description: Agent 3 (document mutation) fires only for specific session types. These types must match the Session Type Reference in apex-doc-formats.md. A missing type causes document updates to be skipped for that session type.
- targets: `skills/apex/apex-tail.md`, `skills/apex/apex-doc-formats.md`
- pre-filter: `audit-remediation|prd-implementation|audit-matrix-remediation`
- property: The set of session types in Agent 3's conditional matches the set defined in Session Type Reference
- pass: All session types from Session Type Reference appear in Agent 3's condition and vice versa
- fail: A session type exists in one source but not the other
- severity: high
- source: apex-tail.md, apex-doc-formats.md Session Type Reference

## TAIL-03: Lessons-only mode correctly skips non-learn agents
- description: Lessons-only mode (used after document output in Step 2.6a) must skip Agent 2 (update), Agent 3 (document mutation), and inline diff. It must spawn Agent 1 unconditionally (without PRE-FLIGHT evaluation). Incorrect skips cause unwanted side effects in document-only sessions.
- targets: `skills/apex/apex-tail.md`
- pre-filter: `lessons-only|Lessons-only`
- property: Lessons-only section explicitly skips Agent 2, Agent 3, and inline diff, and spawns Agent 1 without PRE-FLIGHT
- pass: All three skips stated and Agent 1 spawned unconditionally
- fail: Missing skip for any of Agent 2/3/diff, or Agent 1 gated by PRE-FLIGHT in lessons-only mode
- severity: medium
- source: apex-tail.md

# Hook Configuration (HOOK)

## HOOK-01: Hook lifecycle events bind to correct scripts
- description: settings.json wires APEX hooks to lifecycle events (PreCompact, PostCompact, StopFailure for precompact-apex.sh; PreToolUse for scope-check-hook.sh; PostToolUse for scan-budget-hook.sh). Wrong event binding causes hooks to fire at wrong times or not at all.
- targets: `settings.json`
- pre-filter: `PreCompact|PostCompact|StopFailure|PreToolUse|PostToolUse`
- property: Each hook's event field matches the intended lifecycle stage for its script
- pass: precompact-apex.sh bound to PreCompact/PostCompact/StopFailure; scope-check-hook.sh bound to PreToolUse; scan-budget-hook.sh bound to PostToolUse
- fail: Script bound to wrong event (e.g., scope-check on PostToolUse instead of PreToolUse)
- severity: critical
- source: settings.json, SKILL.md Step 2

## HOOK-02: Hook matcher patterns cover intended tool operations
- description: PreToolUse scope-check uses matcher "Edit|Write" to intercept file modifications. PostToolUse scan-budget uses matcher "Grep|Glob" to count search operations. Matchers must cover all tools that perform the intended operation type.
- targets: `settings.json`
- pre-filter: `matcher.*Edit|matcher.*Grep`
- property: PreToolUse matcher includes all file-modification tools; PostToolUse matcher includes all search tools
- pass: Edit|Write covers file modifications; Grep|Glob covers search operations
- fail: A tool that performs the operation type is missing from its hook's matcher
- severity: high
- source: settings.json hook configuration

## HOOK-03: Hook scripts parse lifecycle event JSON correctly
- description: Hook scripts receive JSON on stdin from the Claude Code lifecycle system. scope-check-hook.sh (PreToolUse) must extract tool_input.file_path. scan-budget-hook.sh (PostToolUse) must parse the event without relying on undefined fields. precompact-apex.sh must extract hook_event_name. Incorrect parsing causes hooks to silently fail or misfire.
- targets: `skills/apex/scripts/scope-check-hook.sh`, `skills/apex/scripts/scan-budget-hook.sh`, `skills/apex/scripts/precompact-apex.sh`
- pre-filter: `json\.load|tool_input|hook_event_name`
- property: Each hook script's JSON parsing targets fields that exist in the corresponding lifecycle event schema
- pass: scope-check extracts file_path from tool_input; scan-budget parses event without undefined field access; precompact extracts hook_event_name
- fail: A hook script accesses a JSON field not present in its lifecycle event, causing silent failure
- severity: high
- source: scope-check-hook.sh, scan-budget-hook.sh, precompact-apex.sh


# Print Format Consistency (FMT)

## FMT-01: Gate marker formats use consistent pattern
- description: APEX uses print markers for gates, budgets, and decisions (PATH DECISION, SCAN BUDGET, SCOUT MODE, COMPLETENESS, REPLAN, etc.). Each marker format must be used consistently wherever it appears across files.
- targets: `skills/apex/SKILL.md`, `skills/apex/apex-apex.md`, `skills/apex/apex-scout.md`
- pre-filter: `PATH DECISION:|SCAN BUDGET:|SCOUT MODE:|COMPLETENESS:|REPLAN:`
- property: Each marker string is defined once and used consistently in all references
- pass: No marker has conflicting format definitions across files
- fail: Same marker appears with different formats in different files
- severity: medium
- source: SKILL.md, apex-apex.md, apex-scout.md

# Cross-file Alignment (SYNC)

## SYNC-01: Shared-guardrails numbered rule references resolve
- description: Multiple APEX files reference shared-guardrails.md rules by number (e.g., #1, #4, #5, #9, #14, #19, #20). If rules are renumbered or deleted, these references break silently -- the wrong rule gets applied.
- targets: `skills/apex/shared-guardrails.md`, `skills/apex/SKILL.md`, `skills/apex/apex-team.md`, `skills/apex/apex-teammate-workflow.md`, `skills/apex/subagent-delegation.md`, `skills/apex/apex-tail.md`
- pre-filter: `shared-guardrails.*#[0-9]|#[0-9].*shared-guardrails`
- property: Every numbered reference (#N) in any APEX file points to the correct rule in shared-guardrails.md
- pass: All numbered references resolve to the intended rule content
- fail: A numbered reference points to a different rule (due to renumbering) or to a non-existent rule number
- severity: critical
- source: shared-guardrails.md, all referencing files

## SYNC-03: Session type reference used consistently across workflow
- description: apex-doc-formats.md defines session types (audit-remediation, prd-implementation, audit-matrix-remediation) with their path patterns, ID prefixes, and completed-list keys. Every APEX file that branches on session type must use the same type names and semantics.
- targets: `skills/apex/apex-doc-formats.md`, `skills/apex/SKILL.md`, `skills/apex/apex-tail.md`, `skills/apex/apex-verify.md`
- pre-filter: `audit-remediation|prd-implementation|audit-matrix-remediation`
- property: Session type names used in conditional logic across all files match the canonical definitions in apex-doc-formats.md
- pass: All type names are identical and no file uses a type name not in the reference
- fail: A file uses a misspelled or undefined session type name
- severity: high
- source: apex-doc-formats.md Session Type Reference

## SYNC-04: Lesson loading script interface matches SKILL.md protocol
- description: SKILL.md Step 3.5 invokes grep-lessons.sh with `{project-root} {term1} {term2} ...` and expects output with `--- LINES {start}-{end} ---` markers. It invokes update-hit.sh with `{project-root}/.claude/lessons.md {line1} {line2} ...`. Both scripts must accept these exact argument patterns and produce the expected output format.
- targets: `skills/apex/SKILL.md`, `skills/apex/scripts/grep-lessons.sh`, `skills/apex/scripts/update-hit.sh`
- pre-filter: `grep-lessons|update-hit|LINES.*---`
- property: SKILL.md invocation patterns match script Usage documentation and argument parsing
- pass: grep-lessons.sh accepts project-root + terms, outputs LINES markers; update-hit.sh accepts lessons-file + line numbers
- fail: Argument order, format, or count mismatch between SKILL.md and script interface
- severity: high
- source: SKILL.md Step 3.5, grep-lessons.sh Usage, update-hit.sh Usage

## SYNC-05: Compaction hook fields align with CLAUDE.md preservation list
- description: precompact-apex.sh echoes manifest fields for context preservation across compaction. CLAUDE.md Compaction Preservation lists fields that must survive. The script must echo at least every field CLAUDE.md lists, and CLAUDE.md should document every field the script echoes for resumption.
- targets: `skills/apex/scripts/precompact-apex.sh`, `CLAUDE.md`
- pre-filter: `APEX SESSION STATE|Compaction Preservation|current_step|tail_mode`
- property: Fields echoed by precompact-apex.sh match the fields listed in CLAUDE.md Compaction Preservation
- pass: All CLAUDE.md fields (path, step, files, scout findings, tail mode) appear in script output, and all script-echoed fields (task, started, decisions) appear in CLAUDE.md
- fail: CLAUDE.md lists a field not echoed by the script, or script echoes resumption-critical fields not documented in CLAUDE.md
- severity: high
- source: precompact-apex.sh, CLAUDE.md Compaction Preservation

## SYNC-06: Batch-mode path patterns match Session Type Reference
- description: SKILL.md Step 1 batch-mode detection uses path patterns `.claude-tmp/{type}/*.md` to identify session types. These patterns must match the paths defined in apex-doc-formats.md Session Type Reference for session types that route through /apex (audit-remediation, prd-implementation).
- targets: `skills/apex/SKILL.md`, `skills/apex/apex-doc-formats.md`
- pre-filter: `\.claude-tmp/.*\*\.md|\.claude-tmp/audit|\.claude-tmp/prd`
- property: SKILL.md path patterns resolve to the same directories as Session Type Reference paths
- pass: SKILL.md types `audit` and `prd` match Session Type Reference paths `.claude-tmp/audit/*.md` and `.claude-tmp/prd/*.md`
- fail: Path pattern in SKILL.md does not match Session Type Reference (different directory name or extension)
- severity: medium
- source: SKILL.md Step 1, apex-doc-formats.md Session Type Reference


# Reflect and Learn Protocol (LEARN)

## LEARN-01: Lesson write target isolation
- description: apex-learn.md must write only to .claude-tmp/lessons-tmp.md, never to .claude/lessons.md directly. apex-reflect.md must write only to ~/.claude/tmp/apex-workflow-improvements.md, never to .claude-tmp/. Crossing write targets contaminates lesson and workflow-improvement data.
- targets: `skills/apex/apex-learn.md`, `skills/apex/apex-reflect.md`
- pre-filter: `lessons-tmp|lessons\.md|apex-workflow-improvements`
- property: Each file writes exclusively to its designated target and has a forbidden-actions entry preventing cross-writes
- pass: apex-learn.md writes only to lessons-tmp.md (forbidden: lessons.md); apex-reflect.md writes only to ~/.claude/tmp/ (forbidden: .claude-tmp/)
- fail: Either file writes to the other's target, or forbidden actions do not prohibit cross-writes
- severity: high
- source: apex-learn.md, apex-reflect.md

## LEARN-02: Workflow observations routed to reflect, not learn
- description: apex-learn.md must not capture workflow observations (how APEX performed). These belong in apex-reflect.md. Mixing them puts workflow improvement ideas into project-specific lessons files where they are not actionable.
- targets: `skills/apex/apex-learn.md`
- pre-filter: `workflow observations|apex-reflect`
- property: apex-learn.md explicitly states that workflow observations must not be captured and references apex-reflect as the correct destination
- pass: Routing rule and apex-reflect reference both present
- fail: No routing rule, or workflow observations accepted by learn
- severity: medium
- source: apex-learn.md

## LEARN-03: Reflect runs inline, never delegated
- description: apex-reflect.md must execute inline in the main session, not delegated to a subagent. Delegation loses the session context that reflection needs to evaluate (compaction events, tool mismatches, timing).
- targets: `skills/apex/apex-reflect.md`
- pre-filter: `Do not delegate|inline`
- property: Forbidden Actions section prohibits subagent delegation
- pass: "Do not delegate" or equivalent constraint present in Forbidden Actions
- fail: No anti-delegation constraint, or delegation is permitted
- severity: medium
- source: apex-reflect.md Forbidden Actions
