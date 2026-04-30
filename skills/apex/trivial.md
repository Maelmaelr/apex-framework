---
name: trivial
description: Step 5 trivial-branch contract. Inline scope-write + scope pointer + p1.md dispatch when SKILL.md step 5 detection returns trivial. One of three producers of {session}-main-scope.json (alongside zero-layer 6.a and the verify-claims.sh normal path).
---

# trivial (SKILL.md step 5 trivial branch)

Spec: `apex-core.md` "Entry flow" step 5 | `apex-core-overview.md` step 5. Producer for `{session}-main-scope.json` on the trivial path (see `shared-guardrails.md` "Scope write producers" for the full producer set).

## When to invoke

`SKILL.md` step 5 detection returns `trivial` when ALL hold:
- single file edit (or single new file), AND
- no cross-file dependencies surfaced in `{session}-hypothesis.json` (no other modules / barrels / callers implicated), AND
- no new abstractions (no new public symbol, component, or endpoint).

When uncertain: default to non-trivial. Hidden-blast-radius cost dominates the latency saving from skipping scout.

## Inline contract

1. **Write the scope artifact** at `.claude-tmp/apex-active/{session}-main-scope.json` via the `Write` tool, conforming to `schemas/main-scope.schema.json`:
   ```json
   {
     "session": "<8-hex token>",
     "allowed_files": ["<detected file>", "<...standard safety paths...>"],
     "produced_by": "trivial-inline",
     "produced_at": "<ISO-8601 now>"
   }
   ```
   `allowed_files` = the detected single file PLUS the standard safety paths (`.claude-tmp/`, `~/.claude/tmp/`, `/tmp/{session}-*`, project `docs/**`, any `README*`; see `shared-guardrails.md`). The schema's `session` field MUST match the manifest's `{session}` token.

2. **Write the scope-check pointer** at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` via the `Write` tool. The file is a single line containing the absolute path to the scope JSON written in step 1. Required so the PreToolUse scope-check hook can resolve the active scope for any subsequent `Edit` / `Write` (see `shared-guardrails.md` / scope-check hook).

3. **Mark queued tasks 6-9 as completed** (skipped, no-op) on the TaskList - they were never queued in the trivial branch (SKILL Step 0 only enqueues 6-9 on non-trivial), so this is a no-op when only tasks 1-5 exist. If the orchestrator pre-emptively queued them, mark them completed now so the TaskList reflects reality.

4. **Call `p1.md`** - read `~/.claude/skills/apex/p1.md` and follow its instructions. The trivial branch writes NO preflight artifact; p1.0 reads an absent `preflight-{session}.json` and runs the no-findings-consultation branch.

See `shared-guardrails.md` for safety paths, scope-write producers, JSON Schema validation; `p1.md` for the downstream chain.
