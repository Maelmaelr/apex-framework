---
name: trivial
description: Step 5 trivial-branch contract. Inline scope-write + scope pointer + p1.md dispatch when SKILL.md step 5 detection returns trivial. One of three producers of {session}-main-scope.json (alongside zero-layer 6.a and the verify-claims.sh normal path).
---

# trivial (SKILL.md step 5 trivial branch)

Spec: `apex-core.md` "Entry flow" step 5 | `apex-core-overview.md` step 5. Producer for `{session}-main-scope.json` on the trivial path (see `shared-guardrails.md` "Scope write producers" for the full producer set).

Trivial-detection criteria are owned by `SKILL.md` step 5 (canonical: single file + no cross-file deps + no new abstractions; default non-trivial when uncertain). This skill runs only after that decision; it does not re-decide.

## Inline contract

The orchestrator's Step 1 read of `<project-root>/docs/project-context.md` is already in working memory; the trivial branch inherits that architecture awareness without a fresh read - by design, since trivial is the latency-optimized path. See `shared-guardrails.md` "Project context".

1. **Write the scope artifact** at `.claude-tmp/apex-active/{session}-main-scope.json` via the `Write` tool, conforming to `schemas/main-scope.schema.json`:
   ```json
   {
     "session": "<8-hex token>",
     "allowed_files": ["<detected file>", "<...standard safety paths...>"],
     "produced_by": "trivial-inline",
     "produced_at": "<ISO-8601 now>"
   }
   ```
   `allowed_files` = the detected single file PLUS the standard safety paths (`.claude-tmp/`, `~/.claude/tmp/`, `~/.claude/plans/`, `/tmp/{session}-*`, project `docs/**`, any `README*`; see `shared-guardrails.md`). The schema's `session` field MUST match the manifest's `{session}` token. Then enforce producer-validates-before-write per shared-guardrails: `bash $HOME/.claude/skills/apex/scripts/validate-json.sh main-scope.schema.json .claude-tmp/apex-active/{session}-main-scope.json` - exit-1 means malformed; abort with explicit error.

2. **Write the scope-check pointer** at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` via the `Write` tool. The file is a single line containing the absolute path to the scope JSON written in step 1. `cc_session_id` is resolved via `bash scripts/get-cc-session-id.sh` - the canonical helper used by SKILL.md Step 2 manifest creation and `zero-layer-extract.sh`; never re-derive from working memory. Required so the PreToolUse scope-check hook can resolve the active scope for any subsequent `Edit` / `Write` (see `shared-guardrails.md` / scope-check hook).

3. **Call `p1.md`** - read `~/.claude/skills/apex/p1.md` and follow its instructions. The trivial branch writes NO preflight artifact; p1.0 reads an absent `preflight-{session}.json` and runs the no-findings-consultation branch.

See `shared-guardrails.md` for safety paths, scope-write producers, JSON Schema validation; `p1.md` for the downstream chain.
