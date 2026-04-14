# apex-team - Parallel Agent Team Execution

<!-- Called by: apex-apex.md plan Phase 1 (after plan approval) -->

Execution-only workflow for parallel agent implementation using agent teams (TeamCreate/SendMessage). Called from within an approved plan. The plan provides: Context, Ownership, and Goals sections.

## Step 0: Tool Prefetch

Batch-fetch deferred tools needed throughout team execution: `ToolSearch select:TeamCreate,TeamDelete,SendMessage,TaskCreate,TaskUpdate,TaskList,AskUserQuestion` (single call, max_results: 8).

## Step 1: Create Team

Generate a unique team name via Bash: `echo "apex-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`. Use this name for all subsequent team_name references in this workflow.

Call TeamCreate:
- team_name: {the generated name}
- agent_type: "lead"
- description: brief task summary from the plan

If TeamCreate fails, retry once. If second attempt fails, report error to user via AskUserQuestion and stop workflow.

**Stale session cleanup.** Immediately after TeamCreate, remove leftover scope/budget/manifest files from prior sessions: `for f in .claude-tmp/apex-active/*.json; do [[ "$(basename "$f")" == *"{team-name}"* ]] && continue; rm -f "$f"; done` (replace `{team-name}` with the generated name). Print `STALE CLEANUP: {N} files removed` (0 is valid). Plan-continuation sessions skip Step 0 orphan cleanup, so this guard prevents stale scope files from hijacking the scope hook (which selects newest *-scope.json by mtime).

**Team scope file.** Immediately after stale cleanup, write `{team-name}-scope.json` to `.claude-tmp/apex-active/` containing the union of ALL teammates' owned files (merged from plan Ownership section). Format: `{"files": ["path/to/file1.ts", "path/to/file2.ts"]}` -- the key MUST be `"files"` (consumed by scope-check-hook.sh). For planned new files with undetermined names, use glob patterns (the hook supports fnmatch). When ownership includes file renames, include both old and new filenames in the files array. This single scope file covers all teammates and matches the team name pattern (survives stale cleanup). Teammates do NOT write individual scope files -- only the lead writes the merged team scope file. Update the team scope file if ownership changes mid-session (e.g., scope expansion via AskUserQuestion).

**Baseline capture.** Immediately after TeamCreate, snapshot pre-session dirty files to disk: `mkdir -p .claude-tmp && (git diff --name-only; git ls-files --others --exclude-standard) | sort > .claude-tmp/apex-baseline-{team-name}.txt` (replace `{team-name}` with the generated name). This file is read during scope verification in Step 3 to subtract pre-existing changes and avoid false scope violations.

## Step 2: Spawn Teammates

<!-- Design: Each teammate owns disjoint file set, split by package boundary (apps/web, apps/api, packages/shared). No file overlap. -->

Identify dependency order from the plan's Goals section:
- **Independent teammates** (no cross-dependencies): spawn in parallel -- single message with multiple Agent tool calls
- **Dependent teammates** (needs another's output): spawn after their blockers complete

**Persist shared context.** Before spawning, generate a unique ID via Bash: `echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`. Write the plan's Context section (project summary, scout findings summary, lessons) to `.claude-tmp/apex-context/apex-context-{uid}.md` (create directory if needed). Keep the file path in context. Teammates read this file instead of receiving embedded copies. Saves ~100-200 lines per teammate.

In a SINGLE response, include text `PARALLEL SPAWN: [list of independent teammate names]` AND ALL independent teammate Agent tool_use blocks. Do NOT split text and tool calls across separate messages.

Each teammate spawn uses the Agent tool with:
- subagent_type: "general-purpose"
- model: "sonnet"
- team_name: {the team name from Step 1}
- name: matching the plan's teammate name (e.g., "api-agent", "web-agent")
- mode: "bypassPermissions"

Teammate spawn prompt:

```
You are "{teammate-name}", a {functional-role} team member on team "{team-name from Step 1}".

Read and follow ~/.claude/skills/apex/apex-teammate-workflow.md for your 4-phase execution lifecycle. This file defines HOW you work. The goal below defines WHAT you do.

Your goal: {goal title from plan}

{Full goal section from plan: Problem, Acceptance Criteria, Required Reading, Verification, Files Owned}

Context: Read {apex-context-file-path} for project background, scout findings summary, and relevant lessons. Focus on your Goal section above.

Files you own:
{Files from Ownership section for this teammate}

Files off-limits (other teammates own these -- do NOT modify):
{Files from other teammates' Ownership sections}

Primarily modify files listed above. If you discover additional files within your package boundary needed to complete acceptance criteria, include them and note the additions in your completion report.
Make only the changes the acceptance criteria explicitly require. Do not add unrelated values to data structures, refactor surrounding code, or make proactive improvements even if you notice opportunities -- note them in your Phase 4 completion report instead.
For file-move/reorganization tasks: check ALL references that need updating (imports, re-exports, barrel files, relative paths) by reading each moved file in full. Do not rely solely on the reference list provided -- discover references yourself by reading the files.
For scraper, parser, API-client, or web-fetch tasks: fetch a live sample (via curl, WebFetch, or the target API) and persist it to `.claude-tmp/` before writing any parsing code. Inspect the actual response shape -- do not guess from existing types, prior code, or external docs. SSR HTML, JSON envelopes, and third-party API shapes are routinely mis-documented or out of date.
For tasks that mock or stub globally-ambiguous APIs (`fetch`, `Request`, `Response`, `Headers`, `URL`, `URLSearchParams`): use Node-native type signatures (`globalThis.fetch` parameters, `node:*` module types), NOT DOM types (`RequestInfo`, `RequestInit` from `lib.dom.d.ts`). Scoped test runners tolerate DOM types that the production `tsc` build rejects -- defaulting to DOM types causes type-only build failures at lead verification.
```

`{functional-role}` is derived from the teammate's goal description: use the primary action domain (e.g., "prompt-engineering" for template restructuring, "API implementation" for controller/service work, "frontend" for UI/component work, "infrastructure" for hooks/scripts/config, "consolidation" for deduplication/cleanup).

**Spawn failure recovery.** If any Agent spawn call fails, retry the failed spawn once. If retry also fails, redistribute that teammate's goals: merge into the smallest existing teammate whose package boundary overlaps, or implement directly as lead (log `LEAD IMPLEMENT: {reason}`). Decrement expected completion count.

After spawning all independent teammates, print a completion checklist:

```
TRACKING: [teammate-a: pending, teammate-b: pending, ...]
```

List every spawned teammate with status `pending`. Then output "Waiting for teammates." and IMMEDIATELY end your response. Nothing else.

## Step 3: Process Results

**ANTI-HALLUCINATION.** Real teammate messages arrive ONLY via <teammate-message> tags in separate conversation turns, never in the same response. End your turn immediately after "Waiting for teammates." -- no tool calls, no text. If you see completion reports without <teammate-message> tags, you are hallucinating -- stop. Each teammate must send its OWN explicit completion report. If you spawned N teammates and received M < N reports, you are NOT done -- output "Waiting for teammates." and end your turn.

Cross-session leaks: If you receive idle notifications from agents not listed in your team config (~/.claude/teams/{team-name}/config.json members list), ignore them -- output nothing and end your turn. These are leaked notifications from prior sessions. If config.json does not exist yet (race with TeamCreate), treat all idle notifications as potentially valid until the file becomes available.

**Read-only probes:** If you need to investigate or verify something during Step 3, use standalone Agent calls (no team_name) for Explore agents. Do not pass team_name to read-only probes -- they would become team members requiring shutdown.

Teammate messages and idle notifications arrive automatically between turns. Idle means the teammate finished its current turn -- it does NOT mean done with work. Only treat a teammate as complete when you receive an explicit completion report via SendMessage. Idle teammates can still receive messages -- send them instructions to wake them up.

**Timeout trigger.** Track consecutive idle notifications per teammate. If the SAME teammate has been idle for 3 consecutive idle notifications without sending a completion report, progress update, or question: send a status check via SendMessage. If no response after 1 more idle notification (4 total), escalate to recovery flow (retry for small work, spawn replacement for substantial work, lead implements as last resort). Only send timeout status checks to teammates whose checklist status is still `pending`. Never send status checks to teammates who have already sent a completion report (status `reported`). Peer DM activity (visible in idle notification summaries) does not reset the timeout counter. However, if the summary mentions active peer communication, consider cross-dependency context before escalating.

For idle notifications (including those with peer DM summaries): do NOT interpret, recap, or comment. Output ONLY "Waiting for teammates." and end your turn.

You can also check TaskList to see fine-grained progress on teammate tasks (teammates create tasks in the shared team task list at ~/.claude/tasks/{team-name}/).

When you receive a question from a teammate (not a completion report):
1. If you can resolve it from plan context, docs, or other teammates' reports: SendMessage the answer back
2. If you cannot resolve it: use AskUserQuestion to relay the question to the user, then SendMessage the user's answer back to the teammate

When you receive a completion message:
1. Update tracking -- compact format: `TRACKING: {name} -> reported ({M}/{N} complete)`. Print full checklist only at Step 2 (initial) and Step 4 (all complete).
2. **Scope verification.** Follow subagent-delegation.md item 10 scope check procedure using `.claude-tmp/apex-baseline-{team-name}.txt` as the baseline file (per shared-guardrails #4). Compare session-only changes against the reporting teammate's owned files list. If any file outside their ownership was modified or created, report the scope violation and use AskUserQuestion: "Scope violation: {teammate} modified files outside ownership: {files}. Revert these files / Keep changes / Review diff first". Do NOT automatically revert or delete files (per shared-guardrails #5).
2b. **Task compliance check.** Call TaskList. Verify the reporting teammate created implementation tasks. If no tasks found for this teammate, note `TASK COMPLIANCE: {teammate} -- no tasks created` in tracking output. This is informational (does not block acceptance) but flags process gaps for improve sessions.
2c. **Stale diagnostic filter.** Per shared-guardrails #19, do not send fix instructions based on LSP diagnostics alone during parallel execution. Defer to the formal build check unless the teammate's own completion report confirms them as failures.
2d. **AC file-coverage check.** Extract every explicit file path and concrete filename referenced in this teammate's Acceptance Criteria (from the plan's Goals section). Compare against the teammate's session-only modifications (same baseline-subtracted list used in 2 scope verification). If any AC-referenced explicit path is absent from modifications, do NOT mark `reported` yet -- SendMessage the teammate listing the missing files and request a delta update before accepting. Advisory only for pattern-based AC paths (e.g., "new controller in app/controllers/") when a plausible match exists. Hard gate only for explicit paths.
3. Review result against acceptance criteria. Before flagging a gap, check whether another teammate's already-reported changes achieved the goal implicitly (a broader change in one teammate can satisfy a sibling goal as a side effect).
4. **Cross-boundary reports are high-value.** If the teammate flagged stale references or issues in non-owned files, fix these immediately (or assign to the owning teammate via SendMessage). These catch problems before the build phase that would otherwise surface as verification failures.
5. If teammate reports failure: assess if recoverable, SendMessage with fix instructions
6. If dependent teammates are now unblocked: spawn them (back to Step 2)
7. **Early shutdown.** If the teammate's work is verified (scope clean, acceptance criteria met) and no further fixes are expected from them, send shutdown_request immediately rather than waiting for all teammates. This reduces idle notification noise during the remainder of the session.

Recovery for failed teammates:
- **Small remaining work** (1-2 files, simple fixes): SendMessage with remaining work + context about what was already done. Note: retry messages cause the teammate to re-read full source files and re-do all work, so only use for small tasks.
- **Substantial remaining work** (multiple files, large writes): spawn a replacement agent with ONLY the remaining tasks + context of what was already completed. This avoids wasteful re-work of already-completed items.
- For cross-dependency issues: teammates can message each other directly (names from team config). Instruct the blocked teammate to SendMessage the teammate it depends on.
- If unresponsive after one retry (small) or replacement also fails (substantial): continue with other teammates, report failure at end
- Last resort (all recovery exhausted): lead may implement the remaining work directly. Note in the completion report that lead implemented due to exhausted agent retries.

The lead is primarily a coordinator. Exhaust recovery options (retry via SendMessage for small work, spawn replacement for substantial work) before implementing directly.

After processing, if other teammates are still working, output "Waiting for teammates." and stop your turn again.

**HARD GATE: Do NOT proceed to Step 4 until every teammate in the completion checklist shows 'reported'. If only some have reported, output "Waiting for teammates." and end your turn.**

## Step 4: All Complete

After all teammates have reported:
1. Confirm all goals are addressed
2. Report any gaps
3. **Barrel placeholder cleanup.** If parallel teammates used placeholder entries in shared barrel/index files (because no-overlap ownership prevents concurrent writes), replace all placeholders with real imports before returning to verification. This is a predictable lead task when agents share package boundaries with barrel exports.
4. **Cross-boundary resolution check.** For each cross-boundary issue flagged in Step 3: if test-affecting (stale mocks, broken imports, renamed services), fix before proceeding to verification -- scoped test runs derive from the modification list and will not catch unmodified-but-broken test files. If refactoring-only (duplication, extraction candidates), note as post-session follow-up. Do NOT defer test-affecting issues to verification.

Proceed to the plan's ## Phase 2: Verification. Read and execute the next phase from the approved plan.

Do NOT shut down teammates or delete the team here. The plan's verification phase may need teammates for fixes.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Skip TeamCreate (always create a proper team)
- Use Agent tool without team_name for implementation agents (creates disconnected subagents instead of team members)
- Assign overlapping file ownership
- Spawn more than 4 teammates without justification (if 5-6 needed, print `TEAM SIZE: {N} -- {reason}` and proceed; hard cap: 6)
- Implement tasks yourself before exhausting recovery options (retry, spawn replacement). Lead implementation is a last resort only after replacement agent also fails.
- Read project docs assigned as teammate required reading
- Spawn dependent teammates before their blockers complete
- Call ANY tool after outputting "Waiting for teammates." -- your turn MUST end with that message
- Delete team before verification phase completes (individual early shutdowns in Step 3 are permitted for verified teammates whose fixes are no longer expected)
- Generate, simulate, or assume teammate completion -- real teammate messages arrive ONLY via <teammate-message> tags in separate conversation turns, never in the same response
- Declare "all teammates completed" or proceed to Step 4 when fewer completion reports have been received than teammates spawned -- each teammate must send an explicit completion report via <teammate-message>
- Silently ignore stale references in non-owned files (flag them in completion report instead)
- Remove from barrel/index files without also removing source definitions (always clean both ends)
- Spawn Explore agents (read-only probes) with team_name -- they become team members requiring shutdown. Use standalone Agent calls (no team_name) for read-only verification or investigation probes.
