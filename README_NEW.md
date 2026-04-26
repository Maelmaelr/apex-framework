# APEX Framework

> APEX turns feature requests into clean, integrated code, and leaves the codebase better than it found it. Every session stays in scope, verifies its own work, and learns from what went wrong - so the next one reaches further with less effort. APEX is allowed to grow new skills, but every skill file must stay lean: nothing new gets added inside unless something else earns its place. Today it ships features solo or via delegated teams. The goal is whole modules - you're the CEO with the vision, APEX is the CTO that ships it.

An opinionated operating system for Claude Code. APEX replaces ad-hoc "just go fix it" prompting with a deliberate, self-improving pipeline: scout, plan, delegate, verify, learn.

This repository is the public mirror of my personal configuration. Fork it, install it, or cherry-pick.

---

## Why

Out of the box an LLM assistant is fast but forgetful, confident but shallow, and drifts off scope the moment work gets delegated. Long sessions lose state. Subagents silently edit files nobody asked about. Scouts hallucinate findings that look plausible but cite wrong line ranges. Docs go stale. Audits rely on "I already checked that." Destructive commands and secret files are one typo away. Hard-won lessons evaporate the moment the session ends. APEX exists to remove those failure modes.

---

## How

The main coding workflow enters through `/apex <prompt>`. One entry point, execution shapes sized to the work.

### Entry flow (every non-trivial run)

1. **Analyze.** Ambiguous prompts trigger `AskUserQuestion` - assuming is forbidden.
2. **Session manifest.** A `{session}` token is generated to isolate concurrent runs and persist state across context compaction.
3. **Hypothesis.** A first-pass model of what the change touches, written down before scouting so bias is visible.
4. **Lessons load.** Keywords from the hypothesis grep the lessons index; prior sessions speak first.
5. **Triviality gate.** Single file, no cross-file deps, no new abstractions -> skip the scout pipeline and go straight to Path 1.

For everything else, the scout pipeline runs:

6. **Scout phase 1 - find what's relevant.**
   - **6a. Deterministic enumeration** (scripts only): static imports, LSP refs, grep patterns, dynamic-import sweeps, framework conventions. Ground-truth file list, not an LLM guess. Falls back to grep-only with an explicit warning if the primary pass fails.
   - **6b. Preflight sizing + shard plan.** A planner reads 6a and decides how many shards, where the boundaries fall (directory, dep-graph cluster, file-type), and what each shard's screening prompt looks like.
   - **6c. Parallel LLM screening.** N Sonnet subagents fan out, one shard each. Each returns a pointer plus a one-line decision signal - never the findings body - so the orchestrator stays small.
7. **Scout phase 2 preflight (Opus).** Reads the screened findings and decides `missed_regions`, `effective_blast`, and `mode`. If clean and small, it's medium mode. Otherwise complex mode, and a **7.x targeted re-scout** re-enumerates the missed regions and merges back in. Complex mode is sticky.
8. **Claim verification.** Every reason-string and line range from steps 6c and 7 gets re-read and confirmed. Bad claims are dropped mechanically. >20% screened claims bad -> re-run 6c. >20% preflight claims bad -> abort and surface to the user. Anti-hallucination is a phase, not a hope.
9. **Path decision.** A script reads the preflight mode: `medium -> Path 1`, `complex -> Path 2`.
10. **Self-reflect (Path 2 only, in background).** The entry-flow run feeds the improvement log without blocking execution.

### Path 1 - Direct

Small, single-concern changes. The implementer (Sonnet) runs the file-health check before adding >10 lines to any file, splits if oversized, then makes the change. A verify step runs lint and build and inserts fix tasks if needed. The tail phase updates lessons, docs, and audit/PRD documents. A reflection appends to the improvement log. Session artifacts get cleaned up. An inline summary closes the run.

### Path 2 - Delegated

Cross-cutting or multi-file work. The orchestrator enters **plan mode** and embeds the full plan (team size, per-teammate model, scoped tasks, allowed-files lists) into the plan itself - so it survives the context clearing that follows plan approval.

After the user approves:

1. Each teammate boots with its own Path 1 task list and an allowed-files scope written to `.claude-tmp/apex-active/{session}-{teammate-id}-scope.json`. A scope-check hook blocks any write outside that list at the tool call.
2. Teammates work in parallel in their own fresh 1M-token contexts. The orchestrator coordinates and waits.
3. Verify, tail, self-reflect, cleanup, summary - same discipline as Path 1, applied to the merged result.

Both paths share the same memory, the same guardrails, and the same verification discipline. The only difference is how much planning and delegation the task warrants.

---

## The Pillars

Ten load-bearing ideas. Everything else in the repo is there to implement them.

1. **Complexity-gated routing.** A triviality gate up front, then a script-driven path decision after scouting. Effort matches the task; one-liners stay one-liners.
2. **Hypothesis before scouting, scouting before code.** The hypothesis is written down so bias is visible. Scouts confirm or correct it. Nothing gets edited before the picture is verified.
3. **Deterministic enumeration first, LLMs second.** Mechanical work (file lists, ref maps, grep sweeps) runs as scripts. LLMs only screen and decide. The ground-truth list is never a hallucination.
4. **Sharded parallel screening.** Scouts fan out across shards in their own contexts and return pointers, not bodies. Findings persist on disk; the orchestrator stays lean.
5. **Anti-hallucination as a phase.** Every claim - file path, line range, reason - is re-read and confirmed before it's allowed to influence the path decision. Bad claims are dropped mechanically; bad-claim ratios trigger re-runs or aborts.
6. **Plan that survives context clearing.** Path 2 embeds the full delegation plan into plan mode itself, so the post-approval context wipe doesn't lose the plan.
7. **Scoped delegation, enforced at the tool call.** Every teammate has an allowed-files list. Edits outside it are blocked by a hook, not caught in review.
8. **Verify, don't trust.** Build, lint, and tests run after every implementation. Failures block completion and insert fix tasks. "It looked right" is not a verdict.
9. **Lessons and scout findings as persistent memory.** Every session reads the lessons index first and writes back what it learned. Scout findings persist on disk. Next run starts with what the last run discovered; duplicates merge, stale entries age out.
10. **Self-improving, safe, lean, resilient.** A reflection step appends to the improvement log every run. Destructive commands, `.env` reads, and force-pushes to main are blocked outright. The session manifest survives context compaction and API failures. Skill files stay lean by rule: nothing new gets added unless something else earns its place.

---

## What You Get

- **Effort matches the task.** Trivial edits skip the ceremony. Big, cross-cutting changes get scouts, a plan, and delegation.
- **No surprise edits.** Non-trivial work is scoped, planned, and user-approved before any file is touched.
- **Findings you can trust.** Deterministic enumeration plus claim verification means "the scout said so" actually means something.
- **Fewer silent failures.** Scope hooks stop runaway edits at the tool call. Bad-claim thresholds force re-runs instead of letting hallucinations drive routing.
- **Shorter, cleaner sessions.** Scouts return pointers, teammates run in fresh contexts, the main session never bloats with implementation noise.
- **Done means tested.** Every implementation run ends with build, lint, and tests. Failures block completion.
- **Code and docs stay healthy.** Files get split before they hit the complexity cliff. Docs update alongside the code that changed them.
- **Cumulative learning.** Lessons and scout findings both persist across sessions.
- **Trustworthy autonomy.** Fail-closed guardrails mean APEX can run without supervision and still stay on rails.
- **Long runs don't lose state.** Session state survives context compaction and API failures.
- **A framework that evolves with you.** The improvement log turns your own transcripts into sharper skills - and the lean-skill rule keeps them sharp.

---

## Install

```
npx create-apex
```

Re-run `npx create-apex upgrade` to refresh skills without touching your CLAUDE.md. For manual install, hook configuration, and the full skill reference, see [README.md](README.md).

---

let's start creating new apex v1.0