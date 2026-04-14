# Skill Quality Audit Criteria Catalog v2.1

## Metadata

- created: 2026-03-29
- updated: 2026-04-05
- criteria-count: 22
- sources: admin-apex Semantic Rules, apex/shared-guardrails.md, admin-apex/SKILL.md, apex-audit-matrix/SKILL.md, apex-brainstorm/SKILL.md, apex-eod/SKILL.md, apex-file-health/SKILL.md, apex-fix/SKILL.md, apex-git/SKILL.md, apex-init/SKILL.md, apex-lessons-analyze/SKILL.md, apex-lessons-extract/SKILL.md, apex-party/SKILL.md, APEX design decisions, workflow analysis
- format: deterministic pre-filters for target-x-criterion matrix generation
- pre-filter-syntax: grep -E (ERE)
- target-syntax: shell glob (compatible with glob.glob() and find)
- project-root: ~/.claude/skills (NOT the application project -- skill files live here)
- purpose: APEX is a structured coding workflow that routes tasks through scan, path selection, implementation, and verification phases. Two paths -- direct (Path 1, single-concern, <=5 files) and delegated (Path 2, scouts, planning, agent teams) -- ensure task complexity is matched by process rigor. Post-implementation tail workflows capture lessons, update docs, and mutate session documents. Quality is enforced through shared guardrails, scan budgets, scope enforcement hooks, and deterministic scripting.
- goal: Consistent, high-quality code changes in one shot. Minimize rework through upfront scanning, pattern discovery, and blast-radius awareness. Capture institutional knowledge via lessons and documentation updates.
- scope-note: Sub-workflow and script criteria target apex/ and admin-apex/ only. Other skill directories (apex-fix, apex-git, etc.) are single-file skills with no sub-workflows or scripts -- their SKILL.md entry points are covered by the */SKILL.md target.
- sources-dirs: apex, admin-apex, apex-audit-matrix, apex-brainstorm, apex-eod, apex-file-health, apex-fix, apex-git, apex-init, apex-lessons-analyze, apex-lessons-extract, apex-party
- excluded: README.md (repo metadata), apex/tests/ (test fixtures), apex/effort-trigger.txt (runtime keyword -- not a skill file), apex/apex-scout-audit-checklist.md (runtime-generated checklist), apex/apex-plan-template.md (plan template -- not an executable workflow), apex-brainstorm/brain-methods.md (static data), apex-init/context-template.md (static data), apex-party/personas.md (static data)


# Entry Point Structure (ENTRY)

## ENTRY-01: YAML frontmatter present
- description: Every SKILL.md entry point must have valid YAML frontmatter with name, description, and triggers fields. Missing frontmatter prevents Claude Code from discovering and invoking the skill.
- targets: `*/SKILL.md`
- pre-filter: (none -- always applies)
- property: File starts with --- delimited YAML block containing name, description, and triggers
- pass: Valid frontmatter with all three required fields present
- fail: Missing frontmatter, or missing name/description/triggers field
- severity: critical
- source: Claude Code skill format requirements

## ENTRY-02: Forbidden Actions section present
- description: Every entry point skill must end with a Forbidden Actions section that references shared-guardrails.md and adds skill-specific constraints. This is the enforcement mechanism for workflow guardrails.
- targets: `*/SKILL.md`
- pre-filter: (none -- always applies)
- property: File contains a Forbidden Actions section referencing shared-guardrails.md
- pass: Forbidden Actions section present with "read shared-guardrails.md" instruction
- fail: No Forbidden Actions section, or no reference to shared-guardrails.md
- severity: high
- source: admin-apex Semantic Rules (every workflow ends with Forbidden Actions)


# Sub-Workflow Structure (SUB)

## SUB-01: Caller comment present
- description: Sub-workflow files must have a caller comment at the top documenting which skills invoke them. This enables traceability when refactoring and prevents orphaned sub-workflows.
- targets: `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`, `apex-audit-matrix/*.md`
- pre-filter: (none -- always applies)
- property: File starts with (or contains near top) an HTML comment listing callers
- pass: `<!-- Called by: ... -->` or `<!-- Referenced by: ... -->` comment present near file top with at least one caller listed
- fail: No caller/referenced-by comment, or comment is empty
- severity: medium
- source: admin-apex Semantic Rules (callers noted in HTML comment)

## SUB-02: Forbidden Actions or guardrails reference
- description: Sub-workflow files should either have their own Forbidden Actions section or reference shared-guardrails.md. Without constraints, sub-workflows can violate workflow invariants.
- targets: `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: (none -- always applies)
- property: File contains Forbidden Actions section or shared-guardrails.md reference
- pass: Forbidden Actions section present, or file references shared-guardrails.md
- fail: No guardrail enforcement mechanism in the sub-workflow
- severity: medium
- source: admin-apex Semantic Rules

## SUB-03: Caller comment callers are accurate
- description: The callers listed in a sub-workflow's HTML comment must actually reference the file. Stale caller lists (referencing deleted callers or missing new callers) mislead refactoring and produce incorrect blast-radius assessments.
- targets: `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: (none -- always applies)
- property: Every caller/referencer listed in the comment actually references this file, and no unlisted callers exist
- pass: All listed callers/referencers reference this file, and grep finds no additional callers
- fail: A listed caller does not reference this file, or an unlisted caller does
- severity: medium
- source: admin-apex Semantic Rules (callers noted in HTML comment)


# Cross-References (REF)

## REF-01: Script path references resolve
- description: Skill files referencing scripts (scripts/*.sh, scripts/*.py) must point to files that actually exist. Broken script references cause silent failures during workflow execution.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: `scripts/|\.sh|\.py`
- property: Every script path referenced in the file resolves to an existing file
- pass: All script references (paths containing scripts/ or ending in .sh/.py) point to existing files
- fail: A referenced script path does not exist
- severity: high
- source: Workflow reliability

## REF-02: Skill file cross-references resolve
- description: Skill files referencing other skills (via ~/.claude/skills/ paths or relative paths) must point to files that actually exist. Broken cross-references cause workflow failures at runtime.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: (none -- always applies)
- property: Every skill file path referenced in the file resolves to an existing file
- pass: All skill cross-references point to existing files
- fail: A referenced skill file does not exist (moved, renamed, or deleted)
- severity: high
- source: Workflow reliability

## REF-03: Skill listed in admin-apex reference
- description: Every SKILL.md entry point should be listed in admin-apex's Skills section so the full skill inventory is discoverable from one place.
- targets: `*/SKILL.md`
- pre-filter: (none -- always applies)
- property: This skill's directory name appears in admin-apex/SKILL.md Skills section
- pass: Skill directory name found in admin-apex Skills listing
- fail: Skill exists but is not listed in admin-apex reference
- severity: low
- source: admin-apex Skills section (single source of truth for skill inventory)

## REF-04: Script listed in admin-apex inventory
- description: Every script in apex/scripts/ and admin-apex/scripts/ should be listed in admin-apex's Scripts section. Unlisted scripts are invisible to maintainers and may become orphaned without detection.
- targets: `apex/scripts/*.sh`, `apex/scripts/*.py`, `admin-apex/scripts/*.py`
- pre-filter: (none -- always applies)
- property: This script's filename appears in admin-apex/SKILL.md Scripts section
- pass: Script filename found in admin-apex Scripts listing
- fail: Script exists but is not listed in admin-apex Scripts section
- severity: medium
- source: admin-apex Scripts section (single source of truth for script inventory)

## REF-05: Cross-file step and section references resolve
- description: Skill files referencing specific steps, phases, or numbered items in other files (e.g., "Step 2.6", "Phase 4", "shared-guardrails #14") must point to sections that actually exist with those identifiers. Stale step references are a top staleness vector -- step renumbering in one file silently breaks references across the workflow.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: (none -- always applies)
- property: Every cross-file step/phase/section reference resolves to an existing section in the target file
- pass: All referenced steps, phases, and numbered items exist in their target files with the cited identifiers
- fail: A referenced step/phase/section does not exist (renumbered, removed, or misidentified)
- severity: high
- source: Workflow reliability (step renumbering is a frequent maintenance action that creates stale references)


# Quality (QUAL)

## QUAL-01: No markdown tables
- description: APEX semantic rules prohibit tables and diagrams in skill files. Numbered lists should be used instead for structured data. Tables render poorly in agent contexts and waste tokens.
- targets: `*/SKILL.md`, `apex/*.md`, `admin-apex/*.md`
- pre-filter: `\|.*\|`
- property: File contains no markdown table syntax (pipe-delimited rows with separator line)
- pass: No markdown tables found in the file
- fail: File contains a markdown table (pipe-delimited with --- separator row)
- severity: low
- source: admin-apex Semantic Rules (no tables or diagrams)

## QUAL-02: Subagent spawns specify model tier
- description: Every Agent tool invocation should specify the model tier (sonnet, opus, haiku) per the three-tier strategy. Unspecified models inherit the parent's tier, which may be wasteful for read-only scouts.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: `model:.*sonnet|model:.*opus|model:.*haiku|subagent_type|spawn.*agent|Agent tool|Agent.*model`
- property: Agent/Explore subagent spawns include explicit model selection or document the inherited default
- pass: Every subagent spawn point specifies model (sonnet for read-only, opus for deep reasoning, haiku for trivial)
- fail: Subagent spawn with no model specification and no documented rationale for inheritance
- severity: low
- source: admin-apex Model Selection (three-tier strategy)

## QUAL-03: Subagent prompts include output constraints
- description: Subagent prompt templates must include ASCII-only and no-tables constraints. Without these, subagents may produce output that violates APEX semantic rules.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`
- pre-filter: `ASCII only|No tables|subagent.*prompt|prompt.*subagent`
- property: Subagent prompt templates include output format constraints (ASCII only, no tables)
- pass: Prompt templates include "ASCII only" or equivalent output constraint
- fail: Prompt template has no output format constraints for the subagent
- severity: medium
- source: shared-guardrails.md #15 (subagent prompts must include constraints -- mandatory, not optional)

## QUAL-04: Numeric limit consistency across files
- description: Budget numbers, thresholds, and retry limits referenced in multiple files must agree. Examples: scan budget (5 Grep/Glob), retry limit (max 3), file size thresholds (400/500 lines), economy tail thresholds (<=5 files, <=80 lines). A divergence means one file enforces a different limit than another, producing unpredictable behavior.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: `max [0-9]|budget.*[0-9]|threshold|<=.*files|<=.*lines|>[0-9].*lines`
- property: Numeric limits referenced in this file match the canonical value in the defining file (SKILL.md for scan budget, shared-guardrails.md for retry limit, etc.)
- pass: All numeric limits in this file are consistent with their canonical definitions
- fail: A numeric limit differs from the canonical value (e.g., file says "max 4 retries" but shared-guardrails #8 says "Max 3")
- severity: medium
- source: Workflow consistency (limits enforced at multiple points must agree)

## QUAL-05: Shared-guardrails numbering integrity
- description: shared-guardrails.md items are referenced by number throughout the workflow (e.g., "shared-guardrails #14", "#15"). Items must be sequentially numbered with no gaps or duplicates. A renumbered or removed item silently breaks all cross-references.
- targets: `apex/shared-guardrails.md`
- pre-filter: (none -- always applies)
- property: Numbered items are sequential (1, 2, 3, ..., N) with no gaps, duplicates, or out-of-order entries
- pass: All items are sequentially numbered and no gaps or duplicates exist
- fail: Gap in numbering (e.g., jumps from 5 to 7), duplicate number, or non-sequential ordering
- severity: high
- source: Workflow reliability (cross-file references by number depend on stable numbering)

## QUAL-06: Skill file size within agent context bounds
- description: Skill files exceeding ~500 lines consume excessive agent context and degrade comprehension accuracy on late-file content. While skill files may be exempt from code file-health hard gates as single-concern continuous documents, oversized files should be split into sub-workflows.
- targets: `*/SKILL.md`, `apex/apex-*.md`, `apex/subagent-delegation.md`, `admin-apex/admin-apex-*.md`
- pre-filter: (none -- always applies, mechanical wc -l check)
- property: File is within reasonable size bounds for agent consumption
- pass: File is <=500 lines
- fail: File exceeds 500 lines (candidate for splitting into sub-workflows or extracting reference sections)
- severity: low
- source: Agent context efficiency, global CLAUDE.md file health rules (adapted threshold for documentation files)


# Script Quality (SCRIPT)

## SCRIPT-01: Usage comment at top
- description: Every script must have a usage comment in the first 5 lines documenting the command-line interface. This enables --help-like discovery without reading the full script.
- targets: `apex/scripts/*.sh`, `apex/scripts/*.py`, `admin-apex/scripts/*.py`
- pre-filter: (none -- always applies)
- property: File has a usage/help comment within the first 5 lines
- pass: Comment with "Usage:" or equivalent describing arguments and purpose
- fail: No usage documentation in the first 5 lines
- severity: medium
- source: admin-apex Scripts section (all scripts support --help)

## SCRIPT-02: Exit code documentation
- description: Scripts must document their exit codes so callers can branch on success/failure/error. Undocumented exit codes force callers to guess at semantics.
- targets: `apex/scripts/*.sh`, `apex/scripts/*.py`, `admin-apex/scripts/*.py`
- pre-filter: `exit|sys\.exit|Exit`
- property: Script documents exit codes in a comment or --help text
- pass: Exit codes documented (e.g., "Exit 0 = success, Exit 1 = no results, Exit 2 = error")
- fail: Script uses multiple exit codes but does not document their meaning
- severity: low
- source: admin-apex Scripts section (use exit codes as signals)

## SCRIPT-03: Hook scripts referenced in settings.json
- description: Hook scripts (scope-check, scan-budget, precompact) must be correctly referenced in ~/.claude/settings.json. A hook script that exists but is not wired in settings.json provides no enforcement.
- targets: `apex/scripts/scope-check-hook.sh`, `apex/scripts/scan-budget-hook.sh`, `apex/scripts/precompact-apex.sh`
- pre-filter: (none -- always applies)
- property: Script path appears in settings.json hook configuration with correct event binding
- pass: Script referenced in settings.json hooks section with appropriate PreToolUse/PostToolUse/PreCompact event
- fail: Hook script exists but is not wired in settings.json, or is wired to wrong event
- severity: high
- source: admin-apex Architecture (scope enforcement hook, scan budget hook, PreCompact hook)

## SCRIPT-04: Shebang line present and correct
- description: Every script must have a proper shebang line as the first line (#!/usr/bin/env bash for shell, #!/usr/bin/env python3 for Python). Missing or incorrect shebangs cause execution failures on systems where the script is invoked directly rather than via an explicit interpreter.
- targets: `apex/scripts/*.sh`, `apex/scripts/*.py`, `admin-apex/scripts/*.py`
- pre-filter: (none -- always applies)
- property: First line is a valid shebang matching the script's language
- pass: `#!/usr/bin/env bash` for .sh files, `#!/usr/bin/env python3` for .py files
- fail: Missing shebang, wrong interpreter, or non-portable shebang (e.g., `#!/bin/bash` instead of `#!/usr/bin/env bash`)
- severity: medium
- source: Script portability best practices

## SCRIPT-05: Bash scripts use error-exit mode
- description: Bash scripts must enable error-exit mode (set -e or set -euo pipefail) near the top. Without this, commands that fail silently allow subsequent logic to operate on corrupt or missing data, producing unpredictable workflow behavior.
- targets: `apex/scripts/*.sh`
- pre-filter: (none -- always applies)
- property: Script has error-exit configuration within the first 5 lines (after shebang and comments)
- pass: `set -e`, `set -eu`, or `set -euo pipefail` present near file top
- fail: No error-exit directive -- script continues silently after command failures
- severity: medium
- source: Defensive shell scripting best practices

## SCRIPT-06: Python scripts import only stdlib modules
- description: Python scripts in APEX must use only standard library modules (no pip packages). Non-stdlib imports break portability across machines without the package installed and violate the "stdlib only" constraint documented in admin-apex.
- targets: `apex/scripts/*.py`, `admin-apex/scripts/*.py`
- pre-filter: (none -- always applies)
- property: All import statements reference Python standard library modules only
- pass: Every import resolves to a stdlib module (os, sys, json, pathlib, subprocess, difflib, hashlib, argparse, glob, re, etc.)
- fail: Import of non-stdlib module that requires pip install (e.g., requests, pyyaml, click)
- severity: medium
- source: admin-apex specification ("python, stdlib only")
