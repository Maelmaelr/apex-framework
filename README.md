# APEX Framework

An opinionated operating system for Claude Code. APEX replaces ad-hoc "just go fix it" prompting with a deliberate, self-improving pipeline: plan, delegate, verify, learn.

This repository is the public mirror of my personal configuration. Fork it, install it, or cherry-pick.

---

## Why

Out of the box an LLM assistant is fast but forgetful, confident but shallow, and drifts off scope the moment work gets delegated. Long sessions lose state. Subagents silently edit files nobody asked about. Docs go stale. Audits rely on "I already checked that." Destructive commands and secret files are one typo away. Hard-won lessons evaporate the moment the session ends. APEX exists to remove those failure modes.

---

## How

The main coding workflow enters through `/apex`. One entry point, execution shapes sized to the work:

- **Path 1 - Direct.** Small, single-concern changes. Scan, route, check past lessons, implement, verify, capture what was learned when the change is non-trivial.
- **Path 2 - Delegated.** Cross-cutting or multi-file work. Parallel scouts map the problem, a plan is drafted for user approval, scoped teammates implement in isolated contexts, a verifier runs build / lint / tests, a tail phase updates lessons, docs, and audit and PRD documents, and a final reflection feeds the self-improvement loop.
- **Audit routing.** When the request is an audit against a known criteria catalog, `/apex` routes straight to coverage-tracked verification, skipping scan and scout.

Both code paths share the same memory, the same guardrails, and the same verification discipline. The only difference is how much planning and delegation the task warrants.

---

## The Pillars

Ten load-bearing ideas. Everything else in the repo is there to implement them.

1. **Complexity-gated routing.** Small work stays direct; big work gets delegated. The router makes the call up front so effort matches the task.
2. **Plan before code.** Non-trivial work runs read-only scouts, writes a plan, and waits for user approval before any file is touched.
3. **Scoped delegation.** Every delegated writer has an explicit allowed-files list. Edits outside that list are blocked at the tool call, not caught in review.
4. **Parallel by default, fresh contexts per worker.** Scouts, teammates, and tail agents fan out in parallel. Teammates run in their own 1M-token contexts so the main session never bloats with implementation noise.
5. **Verify, don't trust.** Every implementation run ends with build, lint, and tests. Failures block completion - "it looked right" is not a verdict.
6. **Coverage-tracked audits with independent verification.** Audits enumerate every check, persist verdicts, and send a separate evaluator to re-check PASS results. Enumeration and other mechanical work runs as deterministic scripts, not LLM prompts. "I already checked that" stops being a valid answer.
7. **Lessons as persistent memory.** Every session writes what it learned; every future session reads it first. Stale entries age out, duplicates get merged.
8. **Codebase-aware context.** Project architecture lives in a pattern-oriented project context file that every scan reads before acting. Scout findings persist across sessions, so understanding accumulates instead of being re-derived each run.
9. **Healthy codebase, healthy docs.** Oversized files are split before they get bigger. Docs are updated in the same step that captures the lesson. READMEs and rules are drift-checked against the real code.
10. **Self-improving, safe, and resilient.** An improvement loop reads real transcripts and rewrites the skills themselves. Destructive commands, `.env` reads, and force-pushes to main are blocked outright; ambiguous state fails closed rather than forward. Session state survives context compaction and API failures, so long runs don't lose their footing.

---

## What You Get

- **Effort matches the task.** Tiny edits skip the ceremony. Big, cross-cutting changes get scouts, a plan, and delegation. No over-engineered one-liners; no under-scoped refactors.
- **No surprise edits.** Non-trivial work is scoped, planned, and user-approved before any file is touched.
- **Fewer silent failures.** Scope checks stop runaway edits. Independent evaluators catch false PASS verdicts.
- **Shorter, cleaner sessions.** Scouts parallelize discovery. Teammates run in their own fresh contexts instead of bloating the main conversation.
- **Done means tested.** Every implementation ends with build, lint, and tests. Failures block completion - not "it looked right."
- **Code and docs stay healthy.** Files get split before they hit the complexity cliff. Docs update alongside the code that changed them. READMEs and rules get drift-checked against the real code.
- **Cumulative learning.** Lessons and scout findings both persist across sessions. Next run starts with what the last run discovered; stale entries age out, but what's useful sticks.
- **Trustworthy autonomy.** Fail-closed guardrails mean APEX can run without supervision and still stay on rails.
- **Long runs don't lose state.** Session state survives context compaction and API failures, so multi-hour runs don't forget what path they were on.
- **A framework that evolves with you.** The improvement loop turns your own transcripts into sharper skills.

---

## Install

```
npx create-apex
```

Re-run `npx create-apex upgrade` to refresh skills without touching your CLAUDE.md. For manual install, hook configuration, and the full skill reference, see [README.md](README.md).
