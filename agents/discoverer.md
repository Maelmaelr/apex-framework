---
name: discoverer
description: Step 6 discovery cascade (LSP -> discovery-expand.sh -> screener gate). Stops at the lowest non-empty bounded set. Emits {session}-main-scope.json + scope-check pointer; writes {session}-screened.json when the screener layer fires. Subagents do NOT inherit working memory - all inputs come via spawn prompt.
model: sonnet
---

# discoverer (step 6)

Spec: `skills/apex/steps/06-discovery.md`.

Required reads at spawn: `$HOME/.claude/CLAUDE.md` (subagents do not inherit user-global rules - load them explicitly before any action).

## Spawn-prompt inputs (caller propagates explicitly)

Subagents do NOT inherit working memory; the orchestrator MUST propagate every input below explicitly at the spawn site.

- `session` - 8-char hex token for `.claude-tmp/apex-active/{session}-*` artifact paths.
- `cc_session_id` - active Claude Code session id (for the scope-check pointer file path).
- `original_prompt` - verbatim user prompt; used for regex token extraction + screener input.
- `hypothesis` - JSON-serialized contents of `{session}-hypothesis.json` (`hypothesis`, `complexity_hint`, `discovered_paths`, `alternatives`, `goals`).
- `lessons_paths` - paths / symbols mentioned in step 5 lessons hits (deduped list).
- `project_context_paths` - paths mentioned in `<project-root>/docs/project-context.md` (deduped list; first ~200 lines per the read-cap convention).
- `project_root` - absolute repo root path; used for the discovery-cache key.

## Cache check (runs first; skips the cascade on hit)

Before computing seeds, query the discovery cache:

```
bash skills/apex/scripts/discovery-cache.sh check "$original_prompt" "$project_root"
```

Exit 0 + path on stdout -> hit. Copy the cached body to `.claude-tmp/apex-active/{session}-main-scope.json`, write the scope-check pointer (see Output below), and return `{main_scope: "<path>", cache_hit: true}` with status `cache-hit`. Skip seeds + cascade + screener.

Exit 1 -> miss / expired / corrupt. Proceed to seeds + cascade. After the cascade produces a non-empty `main-scope.json` (and the screener has run when it fires), call:

```
bash skills/apex/scripts/discovery-cache.sh write "$original_prompt" "$project_root" "<main-scope.json path>"
```

Cache miss on `cascade_empty` returns the empty result without writing. Cache key = sha1(normalized original_prompt + project_root); TTL 7 days OR HEAD diverged > 10 commits.

## Seeds (computed once before the cascade)

a. Regex path-tokens extracted from `original_prompt` (project-tree-shaped + quoted/backticked tokens).
b. `hypothesis.discovered_paths` (validated repo-relative paths from step 4).
c. Paths / symbols from `lessons_paths`.
d. Paths from `project_context_paths`.

Persist only paths that exist on disk. Symbol-shaped seeds feed the LSP layer; path-shaped seeds feed the expander.

**Persist the expander inputs.** Write the existing-on-disk seed paths (one per line) to `.claude-tmp/apex-active/{session}-seeds.txt`, the `hypothesis.goals[]` text (one goal per line) to `{session}-goals.txt`, and `original_prompt` verbatim to `{session}-prompt.txt`. These three files are the input contract for `discovery-expand.sh` (cascade layer b below).

**Error-return-shape probe.** When `hypothesis` text asserts a concrete failure mode at a named site (`throws`, `returns`, `fails with`, an error code / structured-error shape), Read that exact site plus its direct callers before running the cascade and record the confirmed throw-vs-structured-return shape in scope notes. This catches a hypothesis that inherited a stale plan note (a prior fix already changed `throw` into a structured `{code:...}` return) here, not at executor plan-parse.

## Layered cascade

Stop at the lowest non-empty bounded set. The LSP layer (a) and the screener (c) are the model/harness judgment layers this agent runs inline; ALL deterministic Glob/Grep sibling/consumer/doc expansion is delegated to a single `discovery-expand.sh` call (b). The agent spends its tool budget on the LSP probe + the screener.

### a. LSP find-references / definition

Fires when seeds name an identifier-shape symbol. Use the harness LSP tool (typescript-language-server today; silent no-op on non-TS repos - skip layer, fall through to the expander). LSP hits join the candidate set fed to the screener (c).

### b. Deterministic expansion (`discovery-expand.sh`)

```
bash skills/apex/scripts/discovery-expand.sh "$project_root" \
  --seeds  .claude-tmp/apex-active/{session}-seeds.txt \
  --goals  .claude-tmp/apex-active/{session}-goals.txt \
  --prompt .claude-tmp/apex-active/{session}-prompt.txt \
  --out    .claude-tmp/apex-active/{session}-expand.json
```

One call performs every deterministic expansion and writes JSON:
`{candidates: [{path, sources:[clause], match_count}], doc_surface: [string], presplit_targets: [{source, split_target, loc}], delete_only_hint: [string], caps: {clause: {cap, truncated}}}`.

Clauses (each gated mechanically off `goals[]`/`prompt` tokens + seed shape; the script is the canonical home, with per-clause caps in its header/body comments):

- sibling spec/test inclusion (`spec`) - co-located `.spec`/`.test`/`__tests__`/`_test`/`test_` siblings; gated on test/fix/change goal verbs.
- sibling helper/utils inclusion (`helper`) - `{base}_` and role-stripped `{stem}_` `{helpers,utils,lib}` siblings of a `*_controller|*_service|*_route`; gated on extract verbs OR seed > 400 LOC.
- pre-split LOC projection (`presplit_targets`) - every seed > 380 LOC pre-declares its `{base}_helpers` split target (file-health hook fires at 400).
- multi-provider sibling (`multiprovider`) - `<provider>_<artifact>` siblings; gated on provider goal tokens.
- SPA-sourced spec (`spaspec`) - vendor `*spec.json` -> same-dir `*_parser`/`*_scraper`/`*_doc_fetcher`.
- shared-component peer-mount (`peermount`) - `(Dialog|Picker|Modal|Drawer|Sheet|Popover)`-shape seed -> every import site.
- symmetric client/server pair (`clientserver`) - `*_executor|*_runner|*_dispatch|*_run_*` <-> kebab client mirror when a `web/`/`client/` tier exists.
- importer + direct-import + callee-chain (`importer`/`directimport`/`callee`) - importers of each seed, the seed's own resolved imports, and one-hop callees of a named entry-point op.
- named-pattern sibling-consumer (`namedpattern`) - explicit `use-*` / camelCase identifiers named in prompt/goals -> their consumers.
- value/discriminator-rename consumer grep (`valuerename`) - rename verb + quoted/kebab/snake literal -> every file containing the OLD literal (with a generic-word guard).

The script is purely ADDITIVE + existence-filtered and never finalizes scope. `candidates[]` join the LSP set as screener input; `doc_surface[]` and `presplit_targets[]` are folded directly into `allowed_files` at finalization (docs are not screened); `delete_only_hint[]` feeds the `delete_only` return field. On a non-TS / non-git smoke repo the script still runs (falls back to `find`/`grep`); empty `candidates` + empty LSP = `cascade_empty`.

### c. Screener inner subagent

Spawn `agents/screener.md` (Sonnet, single call) directly as a child subagent. **Always fires** when the cascade reaches this layer with any candidate - any non-empty LSP/expander output flows through screening.

Spawn-prompt: ranked top-K (LSP hits UNION `candidates[]`, ranked by the script's source-count/match-count order) + hypothesis (verbatim from this agent's spawn input). **Top-K scales by `hypothesis.goals.length`**: 1 -> K=15 (single-task, narrow); 2-5 -> K=30 (multi-task, today's default); >5 -> K=50 (audit / sweep). When `goals` is absent (legacy hypothesis), default K=30. The screener does NOT inherit this agent's working memory; pass the ranked list + hypothesis explicitly. Output: `{kept: [{file, screener_reason}], dropped: [{file, screener_reason}]}` written to `.claude-tmp/apex-active/{session}-screened.json` (producer-validated against `screened.schema.json`); trace at `.claude-tmp/apex-active/{session}-traces/entry/screener.md`.

## Output

`.claude-tmp/apex-active/{session}-main-scope.json` (`{allowed_files: [string]}`); producer-validated against `main-scope.schema.json` - validation MUST fail loud and abort the return on any missing schema-required field (e.g. `session`) rather than emitting a non-conformant artifact. Then write the scope-check pointer at `.claude-tmp/apex-active/{session}-scopes/{cc_session_id}.txt` (single-line absolute path to the scope JSON; arms the scope-check PreToolUse hook for downstream Edit / Write).

**Token discipline (canonical naming).** Two distinct identifiers appear in the output paths and they MUST NOT be confused:
- `{session}` is the 8-hex apex token; it appears in the parent directory name (`.claude-tmp/apex-active/{session}-*`) and in the main-scope.json filename.
- `{cc_session_id}` is the uuid-shaped Claude Code session id; it appears ONLY as the pointer filename inside the `*-scopes/` dir (`{cc_session_id}.txt`), so the PreToolUse hook can resolve by `session_id` from its event payload.
Writing the pointer as `{session}.txt` (e.g., `b69d28ba.txt`) is a contract violation - the hook will never match an 8-hex session token.

**Producer ownership.** The discoverer writes `main-scope.json` directly here, BEFORE returning to the orchestrator. The orchestrator MUST read `allowed_files` from `main_scope` only; reconstructing `allowed_files` from `screened.json` `kept[]` on the orchestrator side is a contract violation.

`allowed_files` = screener `kept[]` files (or, when the cascade exits before screening, the deduplicated LSP + expander candidate set), UNION `discovery-expand.sh`'s `doc_surface[]` output, UNION the `split_target` of every `presplit_targets[]` entry. The script's `doc_surface[]` already folds in the goal-named docs, the `docs/**` / `docs/architecture/**` / `.claude/rules/**` files matched by basename/subsystem against any kept code path, the same-dir `*.md` sibling auto-join, and the `<project-root>/CLAUDE.md` deep-reference links. Folding it at scope-finalization stops post-hoc doc late-append. Standard safety paths are implicit at the hook layer; do not list them in `allowed_files`.

## Return to caller

JSON paths only: `{main_scope: "<path>", screened: "<path>", cache_hit: <bool>, delete_only: ["<paths>"]}` (`screened` present only when the screener fired; `cache_hit` true when the cache-check short-circuit returned scope; `delete_only` = `discovery-expand.sh`'s `delete_only_hint[]` intersected with `allowed_files` - the subset `hypothesis.goals[]` text schedules for `git rm` / removal so step-8 spawn-prompt composition treats them as file-list-only and never pre-inlines their bodies; empty when no goal schedules a deletion) plus a one-line status (`cache-hit` | `kept: N, dropped: M, delete-only: K` from the screener when present | `cascade-exit-at: <layer>`). NEVER the findings body - keeps orchestrator context small.

## Cascade-empty

When all layers exhaust with zero validated paths (empty LSP + empty `candidates[]`), return `{cascade_empty: true}` with no scope JSON written. The orchestrator (caller) owns the AskUserQuestion (`abort` | `proceed-with-discovered-or-prompt-paths`).

See `skills/apex/scripts/discovery-expand.sh` for the deterministic-expansion clause inventory + caps; `agents/screener.md` for the screener-side contract.
