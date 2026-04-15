# apex-scout - Scout Phase

<!-- Called by: apex-apex.md Step 2 -->

Receives from caller: preliminary file list from SKILL.md Step 2 scan, project-context.md reference, optional `audit` hint.

**Expected scan data structure:** files (path, package, role: entry|dependency|test|type|doc, health: ok|split-first|blocked), patterns_found (strings), counter_evidence (strings), docs_read (paths). When structured, skip Step 2 area identification for covered categories; go directly to Step 3 for areas requiring new reads.

## Mode Selection

- `audit` hint passed: follow Audit Mode.
- Otherwise: follow Exploration Mode. After Step 1 (Assess Scout Need), if findings reveal checklist-shaped scope (many files, similar violation patterns, verification nature, >10 items across >5 files), switch to Audit Mode from Step 1.

Print: `SCOUT MODE: {exploration|audit}` with one-line justification.

## Return Schema

All returns to caller (apex-apex.md Step 2.6):
- **skip**: recommendation=null, findings=null, file_path=null
- **downgrade**: recommendation='downgrade', findings=null, file_path=null, file_list=[paths]
- **question-answered**: recommendation='question-answered', findings=null, file_path=null, answer_summary=str
- **plan-input**: recommendation='plan-input', file_path=str (absolute)
- **audit-document**: recommendation='audit-document', file_path=str (absolute)

## Scan Data Reuse Procedure

Classify each area/item as "scan-answered" (resolvable from SKILL.md Step 2 data already in context) vs "requires new reads". Resolve scan-answered items inline; dispatch only remaining items to scouts. Print: `SCAN REUSE: {N} resolved inline, {M} dispatched`.

If all items scan-answered, skip scout launch; proceed to verification with inline findings.

**Forwarding format** -- serialize as structured key-value, not prose:
```
file_path:
  line_number: content
```
Include only lines relevant to the scout's assigned area.

**Freshness gate (cross-session).** Before reusing prior scout findings (existing `scout-findings-*.md`), run `git log --oneline --since={findings_file_mtime} -- {files_in_findings}`. Commits found: invalidate those files' findings; untouched files remain valid.

**Baseline loading (cross-session dedup).** Before dispatch, check prior findings: Glob `.claude/scout-findings/*.json`. If matching theme exists, load fingerprints via `python3 ~/.claude/skills/apex/scripts/scout-dedup.py --theme {task-theme} --no-persist --findings-file /dev/null` (dry-run), then read the store for fingerprint keys and `raw_text` first lines. Pass to scouts in `<known-findings>` block. Scout instruction: "Skip findings matching known fingerprints. Only report new findings or findings where target file changed." No prior findings: omit block entirely.

**Audit override:** Inline reads during audit Step 1 (beyond primary artifacts and 3-file survey cap) are NOT scan-answered eligible -- loaded for claim generation, not verification. Only SKILL.md Step 2 scan data and capped Step 1 survey qualify. Heuristic: audits with <30 target files where scan has cross-reference data -- link/reference validation is prime inline candidate.

---

## Exploration Mode

### Step 1: Assess Scout Need

**Scout needed IF:** patterns unclear, implementation approach uncertain, or multiple codebase areas need investigation.

**Skip IF:** patterns clear from docs, similar examples found in Quick Scan, changes straightforward. Use **skip** return shape.

**Quick-scope return.** Two triggers:
- <=5 files across <=2 packages AND patterns clear from docs/examples
- Bug report with <=5 concentrated files (same component tree/module) -- SKILL.md Step 2 Exception (b) already identified relevant files; parallel scouts would re-read redundantly

Use **downgrade** return with file_list. Skips Steps 2-6. Print: `SCOUT QUICK-SCOPE: recommend downgrade -- {file count} files, {package count} packages, {reason}`.

**Loop-break override.** If caller passes `quick-scope-rejected: true` in the spawn prompt (from apex-apex.md Step 2.6 re-scout after a rejected downgrade), skip the Quick-scope return path entirely and proceed to Step 2 regardless of file count. This prevents infinite downgrade loops when the same small file list re-triggers the quick-scope threshold on re-entry.

### Step 2: Identify Exploration Areas

Examples:
- Entry points / main files to modify
- Related components / dependencies
- Test files needing updates (enumerate `.test.ts`, `.spec.ts`, `__tests__/` siblings for each source file -- include in modification list)
- Type definitions / shared contracts
- BFF-only vs API-proxy endpoints (BFF routes querying DB directly eliminate API controller changes from scope)
- Similar patterns to follow
- Documentation needing updates
- Task-type-specific checks:
  - **Extraction/split:** Grep tests for `vi.spyOn`/`jest.spyOn` targeting source class
  - **File-move / content change:** Grep tests for hardcoded path refs (`readFileSync`). Enumerate `./sibling` imports. For content changes, grep tests for `readFileSync`/`readComponent` referencing modified file
  - **Shared type additions:** Grep construction sites (object literals, factories, `as TypeName`) across ALL packages
  - **Shared type removals:** Grep literal value across ALL packages (display, tests, i18n, admin constants). Also grep ALL ancestor `index.ts` barrel files up to the package root -- removed exports may be re-exported from parent-folder barrels that won't surface in package-wide consumer grep.
  - **Interface restructuring:** Distinguish surface prop renames from behavioral restructuring (data fetching removed, state relocated). Grep `<ComponentName` across full owning package for all JSX consumers (non-page consumers are primary source of incomplete ownership lists)
  - **Column additions:** Grep aggregate queries (`.count`, `.where`, `.whereNull`) on same table. Check migration archives
  - **Sequential resources:** Read directory listing for current highest sequence number
  - **Integration/event-handling:** Identify handler/state-setter component, not display component

**Reverse dependency search.** For every modification target, grep for what imports/calls/references it. Report both target and consumers. Missing consumers = primary source of missed blast radius.

**Cross-layer chain tracing.** When a finding touches shared type, API response, or BFF route, enumerate the full chain: shared type -> API controller -> BFF route -> frontend hook -> display components. Report all affected layers.

**External package resolution.** If app code searches return no results, check: (a) node_modules/ for framework implementations, (b) framework configs, (c) generated files (.next/, dist/).

**Area dedup.** Print numbered list with primary files and root directory per area. If two areas share >2 target files, merge into single scout area.

**Hypothesis framing.** Per area: specific search hypothesis (expected finding + location). One hypothesis per scout to prevent convergent searches.

**Mandatory: test file enumeration.** For every source file in modification list: (a) `{filename}.test.ts`/`.spec.ts` same directory, (b) `__tests__/{filename}.test.ts`/`.spec.tsx` parent directory, (c) Grep `import.*from.*{filename}` scoped to test directories. Include all discovered test files. Not optional.

## Scout Methodology

### Core Rules <!-- Rules v2 -->

1. Enumerate individual items -- never summarize into totals.
2. Cross-file counts: per-file breakdowns in `file_path: count` format. Verify sum matches total. Reject aggregates without per-file evidence.
3. Cross-file pattern detection: exhaustive Grep across all in-scope files -- no sampling/extrapolation. For marker-enumeration greps (@deprecated, TODO, FIXME), use head_limit: 0.
4. Config/prop usage: trace full chain from declaration to consumption.
5. **Diversified search.** Symbol lookups: LSP first (`findReferences`, `goToDefinition`, `workspaceSymbol`) at ~15 tokens vs ~2,000+ for Grep. Fall back to Grep after 2 consecutive empty LSP queries. Text-pattern searches: generate naming variants (camelCase, snake_case, PascalCase, kebab-case, abbreviations, plural/singular), launch 4-8 parallel Grep/Glob with diversified patterns across scopes. Absence claims: all variants empty AND LSP `workspaceSymbol` empty before reporting. Dead-code claims: also grep type positions (`: ImportName`), JSX tags (`<ImportName`), barrel re-exports, namespace access (`ImportName\.`), object-path access (`obj.name`). Multiline markup: `multiline: true`.
6. **Convergent retry.** 0 or unexpected results: 2+ alternative terms before accepting. Empty = signal to broaden.
7. **Multi-hop chain tracing.** Reference found: trace to source (imports, re-exports, barrels). Definition found: trace to consumers. Both directions in parallel. Monorepo: shared type -> API -> BFF -> frontend hook -> display. Use LSP `goToDefinition`/`findReferences`/`incomingCalls`/`outgoingCalls` for symbol chains; Grep for text patterns. Verify ALL claimed downstream effects independently. For helper-reuse recommendations, verify behavioral semantics match, not just existence.
8. **Early stopping.** 3+ consistent results confirming a pattern: stop collecting evidence for that pattern, redirect to unexplored areas. Rule 3's exhaustive file coverage still applies.

### Audit Mode Only

9. PASS: Cite file path + line/content proving the claim. Never PASS without checking.
10. FAIL: Cite what found instead, or confirm absence after diversified search (rule 5). Never FAIL without targeted search.
11. Flow/behavior claims ("X calls Y"): trace actual call chain -- function existence alone is insufficient.
12. Existence claims: existence check sufficient. Framework-auto-generated elements (Next.js viewport meta, auto-routes) satisfy claims without explicit code. Check framework auto-generation before FAIL.
13. Existence/export claims: check barrel files, re-exports, alias patterns before FAIL. When scouting for symbol removal/rename, grep ALL ancestor-folder barrel/index files (immediate parent, grandparent up to package root) for re-exports of the target, not only the defining folder's barrel -- parent-folder `export * from './subfolder'` and named re-exports are the dominant miss pattern.
14. Before FAIL on behavioral/pattern claims, consider implicit mitigations (naming conventions, framework guarantees, architectural patterns). Uncertain: FAIL with caveat.
15. Before FAIL, steel-man the current code: intentional simplification, framework handling, planned deprecation, performance trade-off, scope limitation. Plausible: FAIL with caveat noting steel-man.
16. Findings touching Security-Sensitive files (per CLAUDE.md): flag implicit dependencies, fragile assumptions, security requirements.
17. Consider intentional architectural delegation before classifying incomplete coverage as FAIL. Trace full event/data flow.
18. FAIL targeting validator: annotate "trace validated data through consuming controller" -- validator may be correct while controller post-validation logic has the issue.
19. Framework-specific behavior assertions: verify against actual framework behavior in current major version. Use context7 MCP tools for authoritative docs.

## Pattern Expansion Procedure

After completeness check, review findings for repeated patterns. If 2+ findings share same issue type:
1. Identify remaining in-scope files not yet checked.
2. **Pre-verify:** 1-2 targeted Greps on candidates. No confirms: skip (false hypothesis).
3. Assign confirmed candidates to single targeted scout (model: "sonnet"): "Pattern found in {N} files: {description}. Check these additional files: {list}."
4. Max 1 expansion round. Prioritize files closest to pattern epicenter.

No patterns at 2+ threshold: skip. Print: `PATTERN EXPANSION: {skip|N items across M files for {types}}`.

**Audit addition:** Domain-critical violations (rate limiting on financial endpoints, auth/ownership gaps, input validation on security routes): expand on 1+ FAIL.

---

### Scout Complexity Classification

Before Pre-Flight Context Assembly, classify each area. Include as `maxTurns` in Agent tool call (ceiling: 20).

- **QUICK** (maxTurns: 8): existence checks, pattern confirmation, count verification
- **DEEP** (maxTurns: 20): cross-file behavioral tracing, absence verification, security chain analysis

Default: DEEP. Print: `SCOUT AREA {N}: {name} -- {QUICK|DEEP} ({reason})`.

### Pre-Flight Context Assembly

<!-- Design: shared between Exploration Step 3 and Audit Step 2 -->

Before launching scouts, assemble context:

**Step A -- Collect scan artifacts.** Per scout area/batch, collect relevant grep results and file snippets from SKILL.md Step 2 scan. Serialize using Scan Data Reuse key-value format.

**Step B -- Batch pre-flight Greps.** Identify key symbols/patterns each area needs. Run ALL anticipated Greps in a SINGLE response (parallel). Do not dispatch until done. Include in each scout's `<pre-loaded-context>`. Preferred format inside `<pre-loaded-context>`: `file_path:line_number: content` triples so scouts skip location-discovery Greps and go directly to behavioral verification. Sibling folders sharing a type via re-export (e.g. `image-generation/` re-exporting from `video-generation/`): pre-flight Grep for the primary implementation's exported symbol name across both folders to surface re-export shims before scout dispatch.

**Step C -- Absence pre-screening.** For items where absence is expected, run multi-variant Grep (camelCase, snake_case, PascalCase, kebab-case) before dispatch. All variants empty: include `pre-screened absent: {symbol} -- all {N} variants empty` in scout's `<pre-loaded-context>`. Scouts verify with one additional approach only.

### Step 3: Launch Parallel Scouts

**Scan data reuse.** Follow Scan Data Reuse Procedure, classifying Step 2 areas.

**Pre-launch file-overlap check.** Each file in at most one scout's prompt. Shared files: assign to most relevant scout; others reference findings.

Launch parallel Explore agents (model: "sonnet", per shared-guardrails #1 and #14) -- ALL in a SINGLE response.

<!-- Sync: When modifying Core Rules (1-8) or Audit Rules (9-19), increment Rules version AND update agents/scout.md # Rules section. Templates below are trimmed -- rules/format/examples auto-loaded from agent definition. -->

**Scout prompt template:**
```
Investigate [area N]: {area description}
Root directories: {root paths from area dedup}

<pre-loaded-context>
{serialized scan grep results -- file_path: [line_number: content]}
{pre-screened absent items, if any}
</pre-loaded-context>

<known-findings>
{fingerprints from baseline loading -- omit block if none}
</known-findings>

Check <pre-loaded-context> before searching. Skip known fingerprints. Report only new findings or changed-file findings. Scope Grep to root directories; grep repo-wide only if scoped search returns 0.

Follow rules, output format, and examples in agent definition.
```

**Memory/config paths for scouts:** Auto-memory: `~/.claude/projects/{project-key}/memory/MEMORY.md` (project-key = working dir with slashes as dashes, dash-prefixed). Global CLAUDE.md: `~/.claude/CLAUDE.md`. Project CLAUDE.md: `{project-root}/CLAUDE.md`.

**Web resource handling:** Include in scout prompts when relevant: "WebFetch blocking response (403, captcha, rate limit): do not retry same domain -- switch to WebSearch. Browser-dependent discovery (DOM, rendered content, visual layout) requires live browser automation -- defer to implementation."

**Total scout failure fallback.** All scouts fail: retry once with halved count (merge adjacent areas). Retry fails: inline verification using pre-flight data from Steps B/C, processing areas sequentially by pre-flight data richness. Print: `SCOUT FALLBACK: inline verification ({N} areas)`.

---

### Step 4: Verify Scout Findings

Classify by evidence type:
- **Tool-backed facts** (grep results, file reads, line citations): TRUST.
- **Existence/pattern claims**: SPOT-CHECK -- verify 2-3 random samples per scout.
- **Absence claims, aggregate counts, dead-code claims, reasoning conclusions**: VERIFY -- independently re-Grep before accepting.
- **Unused/missing binding FAIL verdicts** (ORM columns, type members, exports): grep all consumers. If all access via raw SQL/dynamic property/string keys: reclassify FAIL -> INFO (hygienic, not runtime-breaking).

Cite exact source file paths. Split large audits across parallel agents (3-4 files each).

### Step 4.3: Completeness Check

Reconcile against Step 2 areas. Print: `COMPLETENESS (exploration): {covered}/{total} areas`. Missing <=2: investigate inline. Missing >2: single targeted re-scout. Max 1 round; remaining gaps marked "unscoped" with warning. (Audit mode uses different format -- see Audit Step 4.)

### Step 4.4: Pattern Expansion

Follow Pattern Expansion Procedure above.

### Step 4.5: Security Context in Findings

When findings include API routes, auth-adjacent code, or Security-Sensitive files: annotate with security requirements ("needs CSRF", "needs input validation", "requires auth middleware"). Informs plan acceptance criteria.

### Step 5: Resolve Decision Points

If findings reveal decision points needing user direction (conflicting patterns, multiple valid approaches, docs-vs-code discrepancies): use AskUserQuestion per shared-guardrails #23. Do not pass unanswered questions to caller.

### Step 6: Persist Findings to Disk and Return

**Not optional.** Generate UID: `echo "$(date +%Y%m%d)-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"`. Write collated findings to `.claude-tmp/scout/scout-findings-{uid}.md` (create dir if needed). Format: flat per-item sections only. No tables, no summary grids, no passing items. Only actionable findings. File write BEFORE returning. Use **plan-input** return with absolute path ($PWD).

**Cross-session dedup.** After writing: `python3 ~/.claude/skills/apex/scripts/scout-dedup.py --theme {task-theme} --findings-file {path}`. Print delta. If converged (exit 1): `SCOUT CONVERGENCE: reached -- {pct}% new findings below 10% threshold.`

---

## Audit Mode

For doc-sync, verification, cross-referencing, discrepancy-checking. Deterministic checklist-based scouting.

### Step 1: Checklist Generation

Read target doc(s), extract verifiable claims into numbered checklist grouped by source section.

**Claim types:** file existence, route existence, description accuracy, cross-reference validity, feature completeness, enum/list coverage.

**Primary artifact loading:** When audit targets code with a single comprehensive source (schema dump, master config, type def file), read in main context before generating claims -- enables inline verification of straightforward claims. When targeting external service config (Stripe, OAuth providers), query the external API as primary artifact.

**Quick-answer return.** If audit targets specific behavioral verification (not comprehensive), fully answerable from primary artifacts (<=4 reads), AND no violations found: use **question-answered** return. Skips Steps 2-8. Print: `SCOUT QUICK-ANSWER: question resolved -- {N} files read, no violations`.

**Primary artifact scope:** Primary artifacts = source-of-truth documents driving claim generation. Verification targets checked by scouts via checklist -- do not load all inline. Files read during SKILL.md Step 2 scan (within 3-doc limit) available for reuse. Implementation survey cap: 3 source file reads during checklist generation. Print `TARGET READS: {N}/3`. Exceeding = hard gate.

**Target coverage check.** Cross-reference preliminary file list against checklist. Every file must be target of >= 1 claim. Uncovered files: generate behavioral claim matching audit theme. Print: `COVERAGE: {covered}/{total} ({N} claims added)`.

**Cross-section dedup.** Scan for claims with same target entity AND verification criterion across sections. Merge, keeping more specific evidence. Print: `DEDUP: {N} duplicates merged`.

**Advanced checklist procedures.** For domain-specific procedures, quality gates, advanced claim patterns: read `~/.claude/skills/apex/apex-scout-audit-checklist.md`.

**Persist checklist.** Generate UID, write to `.claude-tmp/scout/audit-checklist-{uid}.md`. Print only total and grouping: `CHECKLIST: {N} claims across {M} sections -- {path}`. Do not keep full text in main context after writing.

### Pre-Flight Context Assembly

Follow shared Pre-Flight Context Assembly above (same Steps A/B/C, applied to checklist batches instead of exploration areas).

### Step 2: Scout Distribution

**Scan data reuse:** Follow Scan Data Reuse Procedure (audit override applies). Verify scan-answered items inline with PASS/FAIL + evidence.

Split remaining items across scouts (4-6 source docs per scout max). Single-source items: split by verification methodology (existence, content, pattern, cross-cutting) rather than file range. Distribute cross-cutting claims evenly across scouts (not concentrated in one). **WebFetch budget:** ~5 per scout -- source-doc limit undercounts when one source spans many pages.

Launch parallel Explore agents per shared-guardrails #1 and #14 -- ALL in SINGLE response.

Scale: one scout per concern boundary. Prefer focused scouts over overloaded ones.

Each scout prompt: assigned item numbers, doc section(s), scope boundary, `<pre-loaded-context>`.

**Scout prompt template:**
```
Read checklist at {path}. Verify items {N}-{M} from [doc], section [section]. Scope boundary: {other scouts' items}.

<pre-loaded-context>
{serialized scan grep results -- file_path: [line_number: content]}
{pre-screened absent items, if any}
</pre-loaded-context>

<known-findings>
{fingerprints from baseline loading -- omit if none}
</known-findings>

Check <pre-loaded-context> before searching. Skip known fingerprints. Report only new/changed findings. Scope Grep to relevant directories; repo-wide only if scoped returns 0.

Follow rules, output format, examples in agent definition. Use audit rules (9-19).
```

**Total scout failure fallback.** All fail: retry with halved count (merge adjacent batches). Retry fails: inline verification using pre-flight data, processing items sequentially. Print: `SCOUT FALLBACK: inline verification ({N} items)`.

### Step 3: Bidirectional Checking

Skip reverse (code->doc) when task explicitly scopes to accuracy only. Reverse checking discovers UNDOCUMENTED items -- valuable only for completeness audits.

**Forward (doc->code):** Handled by Step 2 scouts.
**Reverse (code->doc):** Before launching, main agent must: (a) extract documented items as structured list from target doc, include verbatim; (b) read CLAUDE.md Doc Quick Reference, include relevant doc paths.

Reverse-check instruction: "Scan code for items absent from this list: [list]. Check these docs before reporting UNDOCUMENTED: [paths]. Consider scoping qualifiers and layered architecture (BFF-proxied routes, internal endpoints). Classify: UNDOCUMENTED (likely intentional) or UNDOCUMENTED (likely gap), with reasoning."

### Step 4: Completeness Validation

Reconcile results against checklist. Per claim: verify PASS, FAIL, INFO, or INCONCLUSIVE verdict exists. Print: `COMPLETENESS (audit): {passed} PASS / {failed} FAIL / {info} INFO / {inconclusive} INCONCLUSIVE / {missing} MISSING out of {total}`.

Verdict rules:
- PARTIAL counts as FAIL for routing/thresholds
- INFO excluded from FAIL counts and actionable item routing
- INCONCLUSIVE tracked separately, included in findings with note
- Include partial context in evidence (e.g., "FAIL (Partial: auth present on 8/10 routes)")

Missing items:
1. <=5: verify inline
2. >5: single targeted re-scout with explicit item numbers
3. Max 1 re-scout round; remaining = INCONCLUSIVE

Do not proceed to Step 4.5 until all items have verdicts.

**Cross-scout INCONCLUSIVE reconciliation.** Scan sibling scouts' evidence for resolving information. If sufficient: upgrade inline, note cross-scout source. Print: `RECONCILED: {N} INCONCLUSIVE upgraded`. Only persist remaining INCONCLUSIVE.

### Step 4.5: Pattern Expansion

**First-pass FAIL compilation.** Compile ALL FAILs (scan-answered + scout) into single list. Exclude INFO. Group by violation type. The 2+ threshold counts across this combined list.

Follow Pattern Expansion Procedure (audit addition applies).

### Step 5: Spot-Check Clean Reports

**Skip for:** sections with <5 items; sections with mixed verdicts (self-verifying).

**Remaining sections:** Prioritize >80% PASS rate (highest false-positive risk). All-PASS sections: independently verify 3-5 random items via Grep/Glob/Read. Any spot-check fails: re-scout entire section with tighter scope. Contradictions: re-verify spot-check methodology first (grep pattern, scope, criteria) before invalidating scout results.

### Step 6: Resolve Decision Points

If findings reveal decision points needing user direction: use AskUserQuestion per shared-guardrails #23.

### Step 7: Collate Findings

Collate: verified scout findings, checklist results (per-item PASS/FAIL with evidence), undocumented items from reverse checking, resolved decision points.

**Format:** No tables, no summary grids, no passing items/files. Only failures and actionable items. Flat per-file sections. Header: total counts (e.g., "23 findings across 13 files").

### Step 8: Output Recommendation

>=8 actionable items across >3 files: recommend `audit-document`. Otherwise: `plan-input`. INFO excluded from count.

**Large findings (>100 lines):** Two sections: (a) `## Summary`: counts by category, top 10 highest-impact FAILs with paths, output recommendation. (b) `## Detail`: all per-item verdicts with evidence. Summary is additive structure, not truncation.

Generate UID, write to `.claude-tmp/scout/scout-findings-{uid}.md`. Use **audit-document** or **plan-input** return with absolute path ($PWD).

**Cross-session dedup.** After writing: `python3 ~/.claude/skills/apex/scripts/scout-dedup.py --theme {task-theme} --findings-file {path}`. Print delta. Add convergence metric to header. If converged (exit 1): `SCOUT CONVERGENCE: reached -- {pct}% new findings below 10% threshold.`

---

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md. Additionally:

- Accept summary totals from scouts without per-item enumeration (e.g., "68 routes: all exist" -- require the 68 items listed)
- Let scouts self-determine what to check in audit mode (checklist drives scope)
- Report PASS or FAIL without evidence (file path, line, content)
- Skip bidirectional checking in audit mode (both doc->code and code->doc), except per Step 3 skip condition
- Skip spot-checking clean audit reports
- Pass unresolved decision points back to caller without using AskUserQuestion
- Retry WebFetch on blocking responses (403, captcha, rate limit) -- switch approaches after first failure
- Introduce aggregate counts in checklist claims or scout prompts not in the source document (fabricated counts cause false fails)
- Skip Step 8 output recommendation in audit mode
- Use markdown tables, summary grids, or visual representations in findings (flat per-item sections only)
- Include passing items or passing files in findings (only actionable failures)
