---
name: scout1
description: Scout phase 1 owner (steps 6.a / 6.b / 6.c). Enumerate findings deterministically, shard by sizing rule, parallel-screen via screener subagents, aggregate into screened-{session}.json.
---

# scout1 (step 6)

Spec: `apex-core.md` step 6 (full) | `apex-core-overview.md` step 6 (summary).

TaskCreate (insert before task 7) the 3 sub-tasks:
- **6.a Enumerate** - `scripts/enumerate-scout.sh` -> `findings-{session}.json`
- **6.b Shard** - `scripts/shard-findings.sh` -> `shard-plan-{session}.json`
- **6.c Screen** - parallel `agents/screener.md` per shard -> `shard-{shard-id}-{session}.json`; aggregator merges to `screened-{session}.json`

Routing:
- 6.a exit code 10 (zero-layer): orchestrator AskUserQuestion - see "AskUserQuestion contracts" below.
- 6.b > 8 shards: orchestrator AskUserQuestion - see "AskUserQuestion contracts" below.
- 6.c: each screener writes trace at `{session}-traces/entryflow/screener-{shard-id}-attempt-N.md`.

## AskUserQuestion contracts (orchestrator-side)

Surfaced by `scout1.md` / `scout2.md`; `SKILL.md` step 6 routing is the entry point. Both questions: dismiss / cancel = abort.

```
AskUserQuestion at 6.a (zero-layer; exit code 10 from enumerate):
  - "abort"
  - "proceed-with-prompt-paths"  (regex-extract paths from original_prompt,
                                  validate each on disk, write scope inline + pointer,
                                  SKIP 6.b/6.c/7/8/9, call p1.md directly)
0 validated paths after extraction -> abort like verify exit-1.

AskUserQuestion at 6.b (> 8 shards):
  - "continue"  (no max cap; proceed to 6.c with the wide plan)
  - "refine"    (abort cleanly so user can re-prompt with narrower scope)
```

Aggregation: read each shard-result JSON, merge per-shard kept/dropped, schema-validate, return artifact path to apex.

See `shared-guardrails.md` for safety paths, scope-check hook, JSON Schema validation.

## TaskCreate template

```
TaskCreate "6.a Enumerate"  - blockedBy [5]    - scripts/enumerate-scout.sh --session {session} --hypothesis .claude-tmp/apex-active/{session}-hypothesis.json
TaskCreate "6.b Shard"      - blockedBy [6.a]  - scripts/shard-findings.sh --session {session} --findings .claude-tmp/scout/findings-{session}.json --hypothesis .claude-tmp/apex-active/{session}-hypothesis.json
TaskCreate "6.c Screen"     - blockedBy [6.b]  - parallel screener.md per shard, then aggregator
```

## 6.a layer rules + confidence (carried verbatim through to screener and verify)

Each `findings-{session}.json` entry carries `reasons: [{layer, detail, line_range|null}]` with `layer` in `{static-imports, ast-grep, lsp, framework, ripgrep, rescout}`. `confidence` is derived from layer count:
- `high` - 3+ deterministic layers (static-imports / ast-grep / lsp / framework)
- `medium` - 1-2 deterministic layers
- `low` - ripgrep-only (fallback fired because all 4 deterministic layers produced 0)
- `rescout` layer is special-cased at 7.x merge time (never appears here); see `scout2.md`.

Screener (6.c) consumes confidence to bias keep/drop: `low` -> drop unless positive signal; `medium` -> judgment; `high` -> keep unless clear negative. Verify (8) routes `low` + no `line_range` to unresolved-claim review.

## 6.c aggregator

After all parallel screeners return their shard JSON paths, scout1 invokes the aggregator:

```
python3 scripts/_aggregate_screened.py \
  --session {session} \
  --output .claude-tmp/scout/screened-{session}.json
```

The aggregator globs `.claude-tmp/scout/shard-*-{session}.json`, consumer-validates each (invalid shard files are skipped with a `_meta.warnings` entry; if every shard is invalid, exits 1), concatenates `kept` + `dropped`, producer-validates the merged screened doc, writes to `--output`. Returns 0 on success, 1 on error.

Each kept entry preserves `reasons` + `confidence` forwarded VERBATIM from the screener input (and originally from `findings-{session}.json`); only `screener_reason` is added by the screener.

## Zero-layer proceed (6.a exit code 10)

Orchestrator (NOT scout1) handles the AskUserQuestion. On "proceed-with-prompt-paths":

```
# Regex-extract paths from original_prompt
prompt=$(jq -r '.original_prompt' .claude-tmp/apex-active/{session}-hypothesis.json)
# Two extraction patterns: (1) anything matching project tree, (2) quoted/backticked relative paths
candidates=$(printf '%s' "$prompt" \
  | grep -oE '(`[^`]+`|"[^"]+"|[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)' \
  | tr -d '`"')
validated=()
for p in $candidates; do
  [[ -f "$p" ]] && validated+=("$p")
done
[[ ${#validated[@]} -eq 0 ]] && abort_like_verify_exit_1

# Write scope inline + pointer
jq -n --argjson files "$(printf '%s\n' "${validated[@]}" | jq -R . | jq -s .)" \
  '{session: "{session}", produced_by: "step6a_zero_layer", allowed_files: ($files + [".claude-tmp/", "~/.claude/tmp/", "docs/"])}' \
  > .claude-tmp/apex-active/{session}-main-scope.json
mkdir -p .claude-tmp/apex-active/{session}-scopes
printf '%s\n' "$(realpath .claude-tmp/apex-active/{session}-main-scope.json)" \
  > .claude-tmp/apex-active/{session}-scopes/$CC_SESSION_ID.txt
```

Then SKIP 6.b / 6.c / 7 / 8 / 9 (mark TaskList completed as no-op) and call `p1.md` directly with NO preflight artifact written. p1.0 reads absent preflight as no-findings-consultation branch.
