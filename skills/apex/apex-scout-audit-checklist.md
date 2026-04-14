# Audit Checklist Generation -- Advanced Procedures

<!-- Called by: apex-scout.md Audit Mode Step 1 -->

Supplementary procedures for audit checklist generation. Read after core claim extraction (claim types, primary artifact loading, quick-answer return, primary artifact scope, target coverage check, cross-section dedup) is complete.

## Domain-Specific Procedures

**When auditing external requirements:**

**External requirement pre-filtering.** When the audit requires fetching multiple external URLs to establish compliance requirements (e.g., platform guidelines, regulatory docs), classify URLs before bulk-fetching: (a) compliance/policy/guideline docs (likely to contain user-facing disclosure, consent, or ToS requirements) -- fetch first; (b) API reference/spec docs (endpoint behavior, rate limits, request/response schemas) -- fetch only if a specific compliance claim references them. Print: `URL TRIAGE: {N} compliance, {M} deferred API-spec`. This typically saves 2-4 unnecessary WebFetch calls per external-guideline audit.

**Domain-batched fetching.** After URL triage, group remaining fetch-eligible URLs by domain. For domains with 2+ URLs, compose a single broad extraction prompt covering all needed fields and fetch one representative URL (the most comprehensive page) instead of N sequential narrow fetches. Print `DOMAIN BATCH: {domain} -- {N} URLs consolidated to {M} fetches`.

**When auditing schema/migrations:**

**Sequential artifact aggregation:** When building claims from sequential artifacts (migrations, changelog entries, config versions), aggregate ALL artifacts affecting each target entity -- not just the creation/initial artifact. Column-adding, altering, and dropping artifacts are equally relevant.

**File-purpose verification:** Before generating claims that reference specific files found via keyword grep, verify the file's actual purpose (read imports/header/first function) -- file names matching keywords (e.g., "pricing") may handle unrelated domains. When a domain term maps to multiple unrelated subsystems (e.g., "pricing" covers subscription billing AND generation credit pricing), qualify search terms with the specific subsystem name (e.g., "stripe_plan" not "pricing") to avoid generating claims against the wrong subsystem's files. Derive claims from a broad file-type enumeration (e.g., `*.{ts,tsx}` for frontend, not just `*.tsx`) to cover hooks, utilities, and non-component files in the same domain.

## Quality Gates (always, after claim generation)

**Threshold concretization:** When a checklist item involves subjective judgment, define an explicit threshold in the claim text (e.g., '>5 items listed verbatim = violation'). For security-pattern audits, use binary criteria (e.g., 'ownership filter present = PASS, bare findOrFail without user scoping = FAIL').

**Size remediation classification:** When generating C1-SIZE findings, classify the excess content to guide remediation strategy. For each oversized section, determine: (a) discoverable content (items that Glob/Grep can find) -- trim candidate, (b) separable concerns (section covers multiple independent topics that could each stand alone) -- split candidate, (c) narrative bloat (verbose prose restating what code shows) -- compress candidate. Include the classification in the finding text (e.g., "C1-SIZE: 605 lines, excess is primarily discoverable content (props tables, enum values) -- trim candidate"). Remediation agents use this classification to choose between trimming, splitting, or compressing rather than defaulting to trimming.

**Discoverable content rule:** VIOLATION: Doc lists items verbatim that are Glob/Grep-discoverable. CORRECT: Doc directs readers to tooling for discovery. Include this distinction in scout prompts for content completeness items.

Do not introduce aggregate counts ("this section lists N items") in checklist claims or scout prompts. Extract individual claims only -- let the enumeration itself establish the count.

## Advanced Claim Patterns

**Consistency audits (catalog-then-compare).** When auditing for pattern consistency across files (e.g., UI patterns, naming conventions, prop usage) rather than doc-vs-code accuracy, generate catalog-style checklist items that instruct scouts to report exact observed values per file (e.g., "Report the border-radius value used in each card component") rather than PASS/FAIL against a reference. Main context then identifies deviations from the majority pattern. This approach discovers inconsistencies without requiring a pre-defined "correct" value.

**Stale-feature cross-reference (security/feature audits).** After extracting claims from docs, cross-reference recent git history (`git log --oneline -20`) for commits that removed or significantly changed features referenced in the checklist. For claims involving database-backed features, also check migration files (`database/migrations/`) for feature lifecycle evidence (column additions, removals, renames) as a tiebreaker when git log messages are ambiguous. If a commit message or migration indicates a documented feature was removed (e.g., "Remove API key auth"), drop or reclassify checklist items referencing that feature before distributing to scouts. Stale doc claims about removed features produce false findings that waste scout and remediation effort.

**Lesson cross-referencing:** After extracting claims, grep `.claude/lessons-index.md` and `.claude/lessons.md` for terms related to the audited area. If lessons reference audited features, add them as additional checklist items with claim type: "Lesson consistency -- lesson says X, verify against doc/code."

**Cross-cutting consistency synthesis.** After extracting per-section claims, generate cross-cutting claims that test consistency BETWEEN related code paths. These catch issues that per-file/per-section claims cannot. Common cross-cutting patterns:
- Display/counting path vs enforcement path -- do parallel implementations count the same entities?
- Config/type definition vs runtime enforcement -- is every defined limit/gate actually checked at enforcement points?
- Response shape consistency across access levels (admin vs non-admin, per-plan tier) -- are all fields populated for all paths?
- Rate-limit/security consistency across endpoints with similar risk profiles -- do all financial/sensitive endpoints use the same protection level?
- Controller vs orchestrator/scheduler path -- when a feature has dual execution paths (direct controller + orchestrator/scheduler/background-job), do both paths enforce the same guards (auth, ownership, feature gates, quota checks, soft-lock)?
Cross-cutting claims use criterion IDs prefixed with "X-" (e.g., X01, X02) to distinguish from section-derived claims. Generate at least one cross-cutting claim per pair of related subsystems identified in the target file list. Cap at 10 cross-cutting claims per audit.

## Forbidden Actions

Shared guardrails: read ~/.claude/skills/apex/shared-guardrails.md.
