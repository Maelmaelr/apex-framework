---
name: apex-eod
description: End of day. Chains file-health, lessons-extract, admin-apex --improve, lessons-analyze, then apex-git sequentially.
triggers:
  - apex-eod
---

# apex-eod - End of Day

All steps run sequentially. Each runs in an isolated subagent (Agent tool, general-purpose, bypassPermissions) for context isolation between steps.

Steps with pre-flight gates skip their subagent spawn when no input exists, avoiding expensive no-op context builds. Pre-flights are evaluated immediately before each step, not batched upfront -- earlier steps can produce outputs that affect later pre-flights. Step 5 (git) always runs.

## Step 1: File Health

**Pre-flight:** Use Glob `'.claude-tmp/file-health/file-health-*.md'` and count matches. If 0, print "Step 1: skip -- no file health notes" and proceed to Step 2.

Spawn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Run file health remediation"
- prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions in ~/.claude/skills/apex-file-health/SKILL.md. Execute every step. Report the final summary line."

Wait for completion. Print result. Do not re-verify or fix LSP diagnostics in files modified by the subagent -- the subagent's build+lint verification is authoritative (shared-guardrails #19).

## Step 2: Lessons Extract

**Pre-flight (evaluate after Step 1 completes -- Step 1 can produce lessons via tail tasks):** Check `.claude-tmp/lessons-tmp.md` existence and non-empty (`test -s`). If missing or empty, print "Step 2: skip -- no pending lessons" and proceed to Step 3.

Spawn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Run lessons extract"
- prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions in ~/.claude/skills/apex-lessons-extract/SKILL.md. Execute every step. Report the final summary line."

Wait for completion. Print result.

## Step 3: Improve

**Pre-flight (evaluate AFTER Step 2 completes -- Step 2 can route workflow improvements that trigger this step):** Check EITHER `~/.claude/tmp/apex-workflow-improvements.md` existence and non-empty (`test -s`) OR `~/.claude/tmp/apex-claude-code-version.txt` is missing (`! test -f`). If neither condition is true, print "Step 3: skip -- no workflow improvements and version unchanged" and proceed to Step 4.

Spawn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Run admin-apex improve"
- prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions in ~/.claude/skills/admin-apex/admin-apex-improve.md. Execute the --improve flag workflow (no conversationId). You are running as a subagent -- skip the EnterPlanMode/ExitPlanMode steps (the plan approval loop -- proceed directly from analysis to Implementation Protocol). Instead, after analysis (Step 5), execute the Implementation Protocol section directly. Report the final outcome -- either the Phase 4 summary or the reason no changes were made."

Wait for completion. Print the full improve summary (commit, diff stats, per-finding breakdown). Do not abbreviate -- this is the user's primary visibility into what the improve agent changed.

## Step 4: Lessons Analyze

**Pre-flight:** Check `.claude/lessons.md` existence (`test -f`). If missing, print "Step 4: skip -- no lessons file" and proceed to Step 5.

Spawn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Run lessons analyze"
- prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions in ~/.claude/skills/apex-lessons-analyze/SKILL.md. You are running as a subagent -- use deferred routing per Step 6 subagent restriction. Execute every step including spawning your own subagents for freshness checks if needed. Report the final summary."

Wait for completion. Print result.

If Step 4 subagent reports failure, print 'EOD Step 4 failed -- aborting Step 5 to prevent committing partial state.' and skip to Step 6.

## Step 5: Git

Spawn subagent:
- subagent_type: "general-purpose"
- model: "sonnet"
- mode: "bypassPermissions"
- description: "Run apex-git"
- prompt: "ASCII only. No tables, no diagrams. Read and follow all instructions in ~/.claude/skills/apex-git/SKILL.md. Execute every step. Report the final summary line. Context: you are invoked as a subagent of apex-eod -- skip the standalone build check in Step 0."

Wait for completion. Print result.

## Step 6: Report

Print: "EOD complete."

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Do not run Steps 1-5 in parallel (each step depends on the previous)
- Do not run Step 5 before Steps 1-4 complete
- Do not skip steps entirely -- pre-flight gates that confirm no input are permitted
