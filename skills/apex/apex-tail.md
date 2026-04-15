# apex-tail - Tail Workflows (Learn + Update + Document Mutation)

<!-- Called by: apex-apex.md plan Phase 4 (Path 2), apex-apex.md Step 2.6 (audit-document, lessons-only), SKILL.md Step 6A (Path 1). Both paths delegate to this file. Path 1 additionally wraps agents in TaskCreate for observability (see SKILL.md Step 6A). -->
<!-- Sibling pattern: apex-file-health/SKILL.md Step 6 implements a parallel tail pattern (learn pre-flight, update pre-flight, agent spawn). Keep in sync when modifying tail logic. -->
<!-- Diff-write responsibility lives in the caller (SKILL.md Step 6A sub-step 2b, apex-plan-template.md Phase 4, apex-file-health/SKILL.md Step 6). Caller MUST print `DIFF WRITTEN: ...` before invoking this file (lessons-only mode excepted). This is hoisted out of tail to prevent the main agent from batching the Write alongside agent spawns and dropping it. -->

Determine agent set based on tail mode (passed by caller).

**All tail agents MUST be spawned WITHOUT the `team_name` parameter.** Tail agents are subagents that return results directly via the Agent tool response -- they are NOT teammates. This applies regardless of whether the caller has an active team context.

**Pre-flight diff-write gate.** Before proceeding to Step 1, confirm the caller printed `DIFF WRITTEN: .claude-tmp/git-diff/git-diff-{RUN_ID}.md` (or the caller explicitly passed lessons-only mode). If missing and not lessons-only: STOP and print `TAIL ABORT: caller did not write diff summary -- expected DIFF WRITTEN marker before tail invocation`. Do not self-remediate by writing the diff here -- the diff write belongs in the caller so it cannot be dropped into a parallel agent-spawn batch.

## Step 1: Agent Spawns

**Full tail (default):** Evaluate pre-flight conditions, then spawn applicable agents in parallel (foreground only -- never use `run_in_background`):
- **LEARN PRE-FLIGHT:** Evaluate each condition independently, print each result, then apply "ANY yes = spawn":
  - (a) verification had failures that required fixes? {yes|no}
  - (b) implementation involved retries, non-obvious solutions, or mid-implementation self-corrections (reverting own changes within the same file)? {yes|no}
  - (c) task was not mechanical (per shared-guardrails #14 mechanical definition)? {yes|no}
  Print: `LEARN PRE-FLIGHT: {spawn|skip} -- (a)={yes|no} (b)={yes|no} (c)={yes|no}`.
  Agent 1 (model: "sonnet"): Read and follow ~/.claude/skills/apex/apex-learn.md.
- **UPDATE PRE-FLIGHT:** Only spawn Agent 2 if modified file paths match any doc path pattern from CLAUDE.md Doc Quick Reference. Print: `UPDATE PRE-FLIGHT: {spawn|skip} -- {reason}`.
  Agent 2 (model: "sonnet"): Read and follow ~/.claude/skills/apex/apex-update.md.

**Economy tail (trivial changes):** If caller indicates docs may be affected (modified file paths match CLAUDE.md Doc Quick Reference targets), spawn Agent 2 (apex-update.md). Evaluate LEARN PRE-FLIGHT (same conditions as full tail above) -- if any condition is met, spawn Agent 1. No task tracking for economy learn (consistent with SKILL.md "Economy tail skips task tracking"). Conditional agents still apply in economy tail.

**Tail scope pre-extension.** If Agent 2 will be spawned (full or economy tail) and an APEX scope file exists (`.claude-tmp/apex-active/*-scope.json`), extend the scope to include the doc paths from the UPDATE PRE-FLIGHT evaluation before spawning agents. Use the SKILL.md Step 5A scope extension pattern. This prevents the scope-check hook from blocking Agent 2's legitimate doc edits.

## Step 2: Conditional Agent 3 + Inline Cleanup

**Conditional Agent 3 (document mutation, model: "sonnet").** If the current session is `audit-remediation`, `prd-implementation`, or `audit-matrix-remediation` type, spawn alongside the others: Update the session document file. For `audit-matrix-remediation` sessions (document file is `.json`), follow the Matrix Mutation Protocol in `~/.claude/skills/apex/apex-doc-formats.md`. For all other session types, follow the Document Mutation Protocol. Additionally, cross-reference VERIFY FIXES from apex-verify against the document backlog -- verification fixes from shared interface/type changes may incidentally resolve pending items (apply the protocol's cross-reference rule). After mutation (markdown documents only), run structural validation: `python3 ~/.claude/skills/apex/scripts/validate-document.py {document-path}`. If validation fails, fix the reported errors before returning.

**Test-gaps cleanup (inline).** If the implementation summary references `.claude-tmp/test-gaps.md` as the task source, run `rm -f .claude-tmp/test-gaps.md` (Bash) inline. This prevents stale targets from being reprocessed in future sessions.

## Step 3: Lessons-only Mode (overrides Steps 1-2)

**Lessons-only mode (audit-document or prd-document output).** If caller requests lessons-only (audit or PRD document was written, no code changed), spawn Agent 1 unconditionally (LEARN PRE-FLIGHT does not apply in lessons-only mode). Pass explicit context about discovery-phase patterns to the learn agent (scout findings summary, document observations). Do not rely on git diff fallback -- document sessions have no implementation commits. Skip Agent 2 and Agent 3 -- no code changed so doc-update/document-mutation are unnecessary, but discovery sessions surface reusable patterns worth capturing as lessons. The caller skips the diff write entirely in this mode (see caller instructions in SKILL.md / apex-plan-template.md / apex-apex.md Step 2.6).

Each agent's spawn prompt must include:
- A one-sentence role declaration: Agent 1: "You are a lessons-extraction agent responsible for capturing reusable patterns and gotchas from this implementation session." Agent 2: "You are a documentation-update agent responsible for keeping project docs in sync with code changes." Agent 3: "You are a document-mutation agent responsible for updating the session document to reflect completed work."
- The "Read and follow" instruction with the file path above
- Implementation summary (what changed, verification results, issues encountered)
- Agent 1 additionally: files modified list, tricky patterns encountered during implementation, verification outcome (pass/fail, fix count)
- Agent 2 additionally: files modified list, features/behaviors added or changed, relevant doc files from CLAUDE.md Doc Update Rules routing, scout findings summary (Path 2 only)
- Agent 3 additionally: document file path, list of items completed in this session (with their priority tier and ID tags -- for matrix sessions, include cell keys (`target:criterion`) instead of BP-/REQ- IDs), verification fix list (VERIFY FIXES output from apex-verify) for cross-referencing against pending document items

**Agent fallback.** If a tail agent fails to spawn, times out, or hits overload, execute that agent's task directly in the main context. For Agent 1: read and follow apex-learn.md inline. For Agent 2: read and follow apex-update.md inline. For Agent 3: follow the Document Mutation Protocol (or Matrix Mutation Protocol) from apex-doc-formats.md inline. Use the implementation summary already in context -- no additional file reads needed beyond the sub-workflow file.

After all agents return (or complete inline via fallback), print each agent's summary line verbatim.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Read apex-learn.md or apex-update.md yourself instead of delegating to agents -- exception: agent spawn failure/timeout/overload (use the agent fallback procedure above)
- Violate conditional agent routing: Agent 3 fires only for `audit-remediation`, `prd-implementation`, or `audit-matrix-remediation` sessions; never spawn outside those conditions, never skip within them (unless caller requested lessons-only mode)
- Spawn tail agents with team_name parameter (tail agents are subagents, not teammates -- they must return results directly via the Agent tool response)
