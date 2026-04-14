<!-- Referenced by: SKILL.md Step 5A, apex-teammate-workflow.md Phase 2 -->

# Subagent Delegation Protocol

Shared protocol for spawning parallel implementation subagents.

## Pre-Delegation Checks

1. **Shared root cause check** (bug-fix tasks only). When multiple tasks share symptoms pointing to the same callback chain or shared function, read the common parent function first. If a single root cause is identified (fixable in <10 lines), implement the fix inline instead of spawning parallel agents. Parallel diagnosis of a shared root cause wastes tokens and risks conflicting workarounds.
2. **Mandatory dependency gate.** Print the dependency assessment per shared-guardrails #9. Determines parallel vs sequential execution. Do not skip.
3. **Small-change exception.** If an independent change is <=5 lines, execute it inline (TaskUpdate in_progress, implement, TaskUpdate completed). Skip agent delegation -- context isolation provides negligible benefit at this scale. Evaluate per-change, not aggregate. When a batch has both inline-eligible (<=5 lines) and agent-eligible (>5 lines) changes: execute inline changes first, capture pre-agent baseline, then spawn agents for remaining in a single response.

## Spawn Protocol

4. **Pre-spawn baseline:** `git diff --stat > .claude-tmp/pre-agent-diff.stat` (captures dirty-file state so post-subagent check can detect agent modifications to already-dirty files).
5. **Context-first search.** Before issuing Grep/Glob/Read calls, check spawn context (modification list, lessons, scout findings) for the answer. Only invoke search tools for information not provided in context.
6. **Parallel spawn (foreground only):** ALL Agent tool calls in a SINGLE response, never use `run_in_background` (shared-guardrails #1). Batch TaskUpdate(in_progress) with Agent calls in the same response. Model selection: sonnet for explore/read-only/mechanical subagents (scouts, verification, classification, <=1 file rename/prop-thread/import-fix/i18n/simple-extraction), opus for deep reasoning (plan writing, complex multi-file implementation, file splitting), haiku for trivial single-command agents.
7. **Subagent prompt must include:**
   - One-sentence role declaration matching the subagent's functional purpose (e.g., "You are an API implementation agent responsible for controller and service changes.")
   - Explicit scope constraint: "Only modify files assigned to your task. Do not expand fixes to sibling files or other files exhibiting the same pattern unless explicitly listed in your task. If a modified component is consumed by multiple pages/routes, only modify behavior for the page(s) specified in the task. If your task creates new files, do not modify existing source files to support them. Report any needed source changes in your completion message instead."
   - Structured reasoning instruction: "Before making a change, state what the current code does and why the change is needed. If the intent is ambiguous, describe both interpretations before proceeding."
   - Relevant lessons from context (only sections relevant to that agent's files)
   - Project-level tool constraints from CLAUDE.md or context
   - Related existing patterns from modification list (instruct agent to check interaction before adding new components)
   - For file move/rename tasks: instruct to grep moved file for ALL relative links (`../`, `./`, markdown relative paths) and update each one
   - When task adds new state atoms (useState, useRef, stores): instruct to grep for reset/cleanup/initialization functions in same file and update them
8. **Disjoint file rule.** Each subagent edits a disjoint set of files -- same-file changes are dependent and must be sequential. Parallel edits to related files commonly leave orphaned declarations; verification catches these.

## Post-Delegation

9. **Post-subagent follow-up.** After all agents return, review each completion message for reported needed changes (files the agent was scoped out of modifying). If <=5 lines: apply inline. If >5 lines or touches another agent's files: handle per caller protocol (SKILL.md: spawn sequential follow-up agent; teammate: report to lead via SendMessage for cross-boundary fixes).
10. **Post-subagent scope check.** Run `git diff --name-only` and `git ls-files --others --exclude-standard`. Run `git diff --stat` and compare against `.claude-tmp/pre-agent-diff.stat` -- files whose diff line count increased were modified by agents even if already dirty. Compare against allowed file set. If unauthorized files changed or created: report -- do NOT automatically revert or delete (shared-guardrails #5). Clean up: `rm -f .claude-tmp/pre-agent-diff.stat`.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not spawn parallel Agent tool calls across multiple sequential responses -- all in one response (shared-guardrails #1)
- Do not spawn subagents with overlapping file ownership -- same-file changes are dependent and must be sequential (item 8)
- Do not skip the pre-spawn baseline capture (item 4) -- post-subagent scope check relies on it
- Do not omit the explicit scope constraint from subagent prompts (item 7)
- Do not auto-revert or delete files flagged by the post-subagent scope check -- report instead (shared-guardrails #5, item 10)
