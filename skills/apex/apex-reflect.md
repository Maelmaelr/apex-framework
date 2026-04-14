# apex-reflect - Inline Workflow Reflection

<!-- Called by: apex-apex.md Step 4.5 (Path 2, mode: discovery), apex-apex.md plan Phase 4 (Path 2, mode: execution, runs after tail), admin-apex-improve.md Phase 3.7 (mode: execution), SKILL.md Step 6A (Path 2 downgrade only, mode: execution), SKILL.md Step 1.5 sub-step 4 (catalog-routed audit, mode: execution). Path 1 skips reflect unless downgraded from Path 2. -->

<!-- Runs INLINE in the main context (not delegated to a subagent). The main context has full visibility into how the workflow executed -- scan quality, path decisions, scout accuracy, plan quality, team coordination. Subagents lack this visibility, making inline execution essential. -->

## Mode Parameter

Caller passes: `mode` (`discovery` or `execution`), `economy` (bool), and optional flags `has_scan_phase` (default: true), `has_build` (default: true).

- **discovery**: Pre-plan reflection. Only categories 1-6 apply. Step 2 checks scan-phase compliance markers only (items 1-4) -- path-specific and verification markers have not happened yet.
- **execution**: Post-execution reflection. All applicable categories and compliance markers apply. Scan-phase compliance markers require `has_scan_phase: true`. Verification marker requires `has_build: true`.

## Step 0: Economy Gate

If the caller passes `economy: true` (economy tail session):
Print: "Reflect: Economy session -- skipping"
Stop here. Economy sessions rarely produce actionable workflow observations.

## Step 1: Review Workflow Execution

Reflect on the current APEX session. Walk through each applicable category:

1. **scan-accuracy**: significant scan misses discovered later?
2. **path-decision**: correct path choice (1 vs 2)? other path more efficient?
3. **file-enumeration**: missed files from scouts/implementation? symmetric structures caught?
4. **lesson-relevance**: loaded lessons useful? irrelevant lessons wasted context?
5. **subagent-prompts**: agents had enough context? clarification loops?
6. **scout-accuracy** (P2): false negatives/positives? audit checklist distribution bypass?

**Execution mode only** (skip 7-12 in discovery mode):

7. **plan-quality** (P2): scope, ownership, acceptance criteria accuracy, gaps?
8. **team-coordination** (P2): dependencies, blocking, ownership conflicts, communication, cross-boundary resolution completeness?
9. **verification**: first-attempt pass? failure causes? right checks?
10. **token-waste**: unnecessary reads, redundant searches, bloated contexts? Sub-checks: (a) compaction events and cause; (b) tool mismatches (Grep vs LSP, full-file vs targeted Read, sequential vs combined Bash).
11. **bias**: anchoring, confirmation, sunk-cost, authority bias? Counter-check: name first approach and one unexplored alternative (or state why none existed).
12. **teammate-compliance** (P2): apex-teammate-workflow.md phases followed? TaskCreate calls, parallel delegation, structured Phase 3 verification.

Skip categories that don't apply to this session (e.g., skip 6 if no scouts ran, skip 7/8 if no team execution).

**Hindsight prompt:** For each applicable category above, answer: (a) What assumption proved wrong? (b) What signal was available at the time but missed? (c) What would the corrected decision be? Skip if no category produced observations.

## Step 2: Compliance Check

**Discovery mode:** Only scan-phase markers (items 1-4 below) apply -- these are available at discovery time. Skip path-specific markers (items 5-8) and verification.

**Execution mode:** All applicable markers apply. Scan-phase markers require `has_scan_phase: true`. Verification marker requires `has_build: true`.

Check **scan-phase compliance markers** (skip when `has_scan_phase: false`):
- project-context.md was read during scan
- "PATH DECISION" was printed before implementation began
- No source file reads occurred during the scan phase (scan reads docs/structure only) -- exceptions: architecture decision points requiring code flow understanding, and bug investigation where tracing call chains IS the scan
- No subagents were spawned during the scan phase

**Execution mode only** (skip in discovery mode):

Check **path-specific compliance markers**:

**Path 2 only:**
- TeamCreate was called
- Shutdown sequence completed (shutdown_request to all teammates)
- TeamDelete was called after shutdown

**Universal (skip when `has_build: false`):**
- Verification step executed (build + lint)

Tag any discrepancies as `compliance:` category observations. If no discrepancies found, note nothing -- compliance is pass-by-default.

## Step 3: Skip If None

If no workflow observations worth capturing (clean execution, nothing to improve):
Print: "Reflect: No workflow observations"
Stop here.

## Step 4: Write Observations

Append 2-5 bullets to ~/.claude/tmp/apex-workflow-improvements.md (GLOBAL path). This is NOT the project-local .claude-tmp/ directory.

**Volume cap.** Run `wc -l < ~/.claude/tmp/apex-workflow-improvements.md 2>/dev/null || echo 0`. If line count exceeds 50, print "Reflect: apex-workflow-improvements.md has {N} entries (cap: 50). Run /admin-apex --improve to consolidate before capturing more." and stop. Do not append to an overflowing file.

Concrete sequence:
1. `mkdir -p ~/.claude/tmp` via Bash (idempotent, always run)
2. Volume cap check (see above). Stop if exceeded.
3. Dedup check: Grep existing file for each new observation's category + target. Skip substantially similar observations.
4. Append via Bash heredoc: `cat >> ~/.claude/tmp/apex-workflow-improvements.md <<'EOF'` with new bullets. No Read required.

Format:
```
<!-- {date} - reflect -->
- {category}: {raw observation}
- {category}: {raw observation}
```

Categories: Step 1 labels (scan-accuracy, path-decision, file-enumeration, lesson-relevance, subagent-prompts, scout-accuracy, plan-quality, team-coordination, verification, token-waste, bias, teammate-compliance) and Step 2 (compliance).

Structure: `- {category}: {action verb} {target skill file or step} -- {rationale} [{severity}]`. Severity: `high` (rework or >500 tokens wasted), `medium` (suboptimal, no rework), `low` (minor friction). Action verb and target reduce re-parsing overhead in improve analysis.

Write high-level observations only. Abstract away project-specific details (site names, tool names, URLs, selectors, error codes). Describe the pattern or principle, not the instance. This prevents biasing future agents toward specific tools or scenarios. No analysis, no proposed fixes -- admin-apex --improve handles that.

## Step 5: Report

Print: "Reflect: {count} workflow observations captured ({categories covered, e.g. 'scan, verification'})"

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not delegate to a subagent (this runs inline where context is richest)
- Do not analyze or propose fixes (raw observations only -- admin-apex --improve does analysis)
- Do not capture codebase lessons (those belong in apex-learn)
- Do not write more than 5 bullets (keep it lightweight)
- Do not write workflow observations to .claude-tmp/ (project-local) -- the target is ~/.claude/tmp/ (global, shared across all projects)
- Do not Read the workflow improvements file for appending -- Step 4 uses Bash append. A Grep for dedup is permitted.
