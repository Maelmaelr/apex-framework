---
name: plan-mode
description: Path 2 plan-mode chain (p2.0a/b/c). Sequential entry-flow tasks queued by step 9 when decide-path.sh returns complex. Owns EnterPlanMode -> embed delegation plan via planner.md + disjoint-scope validator -> ExitPlanMode (with rejection cleanup).
---

# plan-mode (p2.0a / p2.0b / p2.0c)

Spec: `apex-core.md` "Path 2 (p2)" p2.0a/b/c | `apex-core-overview.md` p2.0a/b/c.

Three sequential tasks in the entry-flow Claude Code session, immediately after step 10 (entry-flow self-reflect runs in the background and does NOT block p2.0a). The plan composed in p2.0b is what survives the p2.0c context clear.

## p2.0a Enter plan mode

Call the `EnterPlanMode` tool. No parameters. After this returns, the orchestrator is in plan mode and any subsequent text becomes part of the plan body.

If `EnterPlanMode` is not in the active toolset (deferred), load it first: `ToolSearch select:EnterPlanMode`.

Do NOT call `EnterPlanMode` more than once per Path 2 run - re-entry has no defined semantics and would discard the planner's draft.

**Forbidden.** `EnterPlanMode` is reachable ONLY through `decide-path.sh = complex` (entry-flow step 9). Calling `EnterPlanMode` at any other point - inline at 6.a / 6.b post-gate, after a manual grep, on a "user UX review" intuition, or anywhere before step 9 has fired - is a contract violation. If the orchestrator finds itself wanting to enter plan mode without 6.c / 7 / 8 / 9 having run, exactly one of these is true: (a) the prompt is genuinely complex - run the full pipeline through `verify-claims.sh` and let `decide-path.sh` decide; (b) the prompt is medium - call `p1.md` directly, no plan mode; (c) the 6.b ripgrep-poisoned gate fired - the only valid post-gate path from there is `zero-layer-extract.sh` -> `p1.md` (see `scout1.md` "Anti-rule (post-gate routing)"). Inline `EnterPlanMode` outside the p2.0a slot bypasses the disjoint-scope validator, the planner.md template, and the post-context-clear `p2.md` entry point - a Path 2 plan composed inline is structurally incomplete by definition.

## p2.0b Embed delegation plan

Read and follow `~/.claude/skills/apex/planner.md`. Inputs (already on disk from earlier steps):
- `.claude-tmp/scout/screened-{session}.json` - kept-files set (scope source)
- `.claude-tmp/scout/preflight-{session}.json` - `effective_blast`, `mode`
- `.claude-tmp/apex-active/{session}-hypothesis.json` - `complexity_hint`, `original_prompt`, `hypothesis`

Compose the plan body per `planner.md` "Plan embed template" - team size, per-teammate model, per-teammate `{teammate-id}` (`openssl rand -hex 2`), per-teammate task description, per-teammate `allowed_files`, and `shared_files`.

Disjoint-scope validator (mandatory before exit). Schema: `plan-candidate.schema.json`. The validator enforces three invariants: (1) per-teammate `allowed_files` pairwise disjoint excluding safety paths, (2) union of allowed_files is a subset of main scope, (3) `shared_files` (if present) disjoint from every teammate's allowed_files.

```
plan_tmp=".claude-tmp/apex-active/{session}-plan-candidate.json"
main_scope=".claude-tmp/apex-active/{session}-main-scope.json"
# orchestrator writes JSON conforming to plan-candidate.schema.json:
#   {"teammates":[{"teammate_id":"ab12","allowed_files":[...]},...],
#    "shared_files":[...]}  # optional

python3 ~/.claude/skills/apex/scripts/validate-disjoint-scopes.py \
  --plan "$plan_tmp" --main-scope "$main_scope" --session "{session}"
```

- exit 0 - all invariants hold, proceed to p2.0c
- exit 1 - violation; stdout lines:
  - `OVERLAP <file>\t<a>\t<b>` -> reassign per planner heuristic (more findings = stronger owner; cross-cutting -> `shared_files`)
  - `NOT_IN_MAIN_SCOPE <file>\t<teammate>` -> planner extends main scope first (single source of truth), then re-runs
  - `SHARED_OVERLAP <file>\t<teammate>` -> remove from teammate `allowed_files` OR remove from `shared_files` (cannot be both)
  - re-run the validator after any reassignment
- exit 2 - input malformed (planner bug, schema violation); abort Path 2 + run `scripts/session-end-hook.sh {session}` inline

After validator exit 0, the **first instruction** in the embedded plan body MUST be:

```
First instruction: read and follow ~/.claude/skills/apex/p2.md
```

Without this, the post-context-clear session has no entry point into the Path 2 chain.

The candidate-plan tmp (`{session}-plan-candidate.json`) is cleaned up by an explicit `rm_target` in `cleanup-session.sh` (no `{session}-*` glob matches it because the `-scope.json` glob is suffix-anchored). Removed at p2.6 / SessionEnd; no inline cleanup needed here.

## p2.0c Exit plan mode

Call the `ExitPlanMode` tool. If not in the active toolset, load it first: `ToolSearch select:ExitPlanMode`. The user is presented the plan and accepts or rejects:

| Outcome | Action |
|---------|--------|
| User accepts | Claude Code clears context; the embedded "first instruction" runs `p2.md` in the new session, which captures baseline + appends `p2_cc_session_id` to the manifest + writes the post-context-clear scope pointer + TaskCreates p2.1 -> p2.7 |
| User rejects | Orchestrator runs `scripts/session-end-hook.sh {session}` inline (cleans manifest + traces + scope + hypothesis + scope-pointer dir, idempotent), surfaces a brief user-facing summary ("Plan rejected; session cleaned up"), and exits cleanly. Distinct from session-level abort (covered by SessionEnd hook) |

Do NOT re-enter plan mode on rejection - that would loop. Treat rejection as terminal for this `/apex` invocation; the user can re-prompt with a refined request.

See `shared-guardrails.md` for safety paths, scope-write producers, manifest schema, mid-/apex abort cleanup.
