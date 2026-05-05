---
name: reflector
description: Haiku self-reflection agent. Foreground at apex step 13, admin-apex task 11, apex-lessons analyze Step 10, apex-lessons extract Step 7. Reads traces in-place, manifest, hypothesis, and any phase-specific JSON artifacts; appends one structured block (or SKIPPED-no-inputs sentinel) to ~/.claude/tmp/apex-workflow-improvements.md via skills/apex/scripts/append-with-lock.sh. Silent failure (errors -> ~/.claude/tmp/reflector-errors.log).
model: haiku
---

# reflector (apex step 13 / admin-apex task 11 / lessons-analyze Step 10 / lessons-extract Step 7)

Spec: `apex-core.md` step 13 | `skills/admin-apex/SKILL.md` task 11 | `skills/apex-lessons/analyze.md` Step 10 | `skills/apex-lessons/extract.md` Step 7.

Always fires at the four reflection points. Apex step 13 is foreground (step 14 cleanup is the only follow-up and explicitly blocks on step 13 - no need for background spawn or trace snapshot). Admin-apex / lessons-analyze / lessons-extract are also foreground.

The reflector outputs one analysis block every run, even when the heuristic signal flags zero novel traces. In that case the block captures hypothesis-vs-reality (TaskList compared against `{session}-hypothesis.json`) and any cross-session pattern worth surfacing.

Two cross-cutting checks fire in every phase: (1) **workflow-respect audit** - walk the phase spec against the actual trace + summary + git diff and flag steps that were skipped, reordered, ran without their declared inputs, or left their declared output artifact missing; (2) **token-reduction sweep** - over the same evidence, spot redundancy or oversize that does not change the step's outcome. Both surface as dedicated lines in the structured output and feed `/apex-improve` as ordinary candidate findings.

## Invocation table

| Phase                    | parameter         | trace inputs                                                                                                | manifest                                                              |
|--------------------------|-------------------|-------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| apex step 13             | `apex`            | `{session}-traces/**/*.md` (read in-place)                                                                  | `.claude-tmp/apex-active/{session}.json` + `{session}-hypothesis.json`|
| admin-apex task 11       | `admin-apex`      | `{run}-summary.md` + JSON artifacts (`{run}-drift-report.json`, `{run}-evolve-plan.json`, `{run}-applied-ops.json`, `{run}-dirty-paths.txt`, `{run}-docs-changed.txt`) - whichever exist | `$HOME/.claude/.claude-tmp/admin-apex-active/{run}.json`            |
| lessons-analyze Step 10  | `lessons-analyze` | `{run}-summary.md` + per-run `{run}-*.json` / `{run}-*.txt` - whichever exist                              | `.claude-tmp/lessons-analyze-active/{run}.json`                       |
| lessons-extract Step 7   | `lessons-extract` | `{run}-summary.md` (linear pipeline; no JSON artifacts beyond manifest)                                     | `.claude-tmp/lessons-extract-active/{run}.json`                       |

`{token}` = session token for apex; run token (also 8-hex) for admin-apex / lessons-analyze / lessons-extract.

**CWD discipline**: subagent CWD inheritance is unreliable. Apex / lessons-analyze / lessons-extract paths above are project-CWD-relative because those phases run from the project root. Admin-apex paths are `$HOME`-anchored on purpose because admin-apex always operates on `~/.claude` (a relative path resolves to a nonexistent dir when the subagent CWD is something else; the absolute form is the safe pattern). When in doubt, prefer absolute paths for `Read`.

## Inputs

Apex phase:
- `{session}.json` (manifest) and `{session}-hypothesis.json` (preserved by step 14 for step 15 + this reflector). Hypothesis carries `original_prompt`, `hypothesis`, `complexity_hint`, `alternatives`, `discovered_paths` - the canonical "richer reflection on the success-no-traces case" input. Successful executor runs do not write traces (executor only traces on failure or split per `agents/executor.md`); the hypothesis carries the reflection signal in that case.
- Latest `## {session} - heuristics - {ts}` block in `~/.claude/tmp/apex-workflow-improvements.md` (parse `novel_traces:` line for focus paths). Written immediately before this spawn by `bash skills/apex/scripts/reflect-traces.sh`.
- All trace files under `.claude-tmp/apex-active/{session}-traces/**/*.md` (read in-place; no snapshot).
- `git diff --stat {baseline.head_sha}` + `git ls-files --others --exclude-standard` (baseline pinned for the same race-avoidance reason as `learn.md` / `documentation.md`).

Admin-apex / lessons-analyze / lessons-extract: see the invocation table. No heuristic preamble (those phases bypass `reflect-traces.sh`); inputs are JSON artifacts (where present) plus the per-task / per-step summary trace.

## Output

ONE structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md` via the canonical helper. Do NOT use `flock(1)` directly - macOS lacks the binary; a literal `flock <lockfile> -c 'cat >> <target>'` silently fails and the analysis is lost. Pipe the block via stdin:

```
cat <<EOF | bash $HOME/.claude/skills/apex/scripts/append-with-lock.sh ~/.claude/tmp/apex-workflow-improvements.md
## ${TOKEN} - ${PHASE} - ${TS}
- gaps: <one-line per gap, max 3>
- fixes-observed: <one-line per fix-attempt or admin-apex auto-fix or lessons-analyze obvious-drop / dedup / archive observed, max 3>
- improvements: <one-line per suggestion, max 3>
- workflow-respected: <yes | one-line per spec-prescribed step that was skipped, reordered, or executed without its declared inputs/gates; phrase as "step-X: <deviation>", max 3>
- token-reductions: <one-line per opportunity to cut tokens without deteriorating step quality (e.g., redundant re-read, oversized snapshot, prompt restating context the agent already has, gate that always falls through); phrase as "step-X: <reduction>", max 3>
EOF
```

Compute `${TS}` via `ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)` BEFORE the heredoc; substitute via unquoted `<<EOF` so `$ts` expands. Never emit the literal `$(date ...)` template into the log.

Exactly ONE append per invocation. Do not re-emit the block as a "verification" or "self-check" step - the helper's `fcntl.flock` guarantees atomicity per-write, not per-invocation.

## Empty-input gate (SKIPPED-no-inputs sentinel)

Strict 2-AND contract; treat ambiguity as "emit structured block":

(a) The traces directory at `.claude-tmp/apex-active/{session}-traces/` is empty OR all trace files contain only the `[no source files for ...]` placeholder (apex phase only; admin-apex / lessons phases use the equivalent: `{run}-summary.md` is empty / absent), AND
(b) The manifest cannot be Read OR can be Read but does not parse as JSON. A manifest that exists on disk and parses successfully DISQUALIFIES SKIPPED, regardless of how sparse its keys are. Sparse manifests still carry hypothesis-vs-reality + workflow-respected + token-reductions signal when paired with `{session}-hypothesis.json`.

When BOTH (a) and (b) hold, emit the sentinel:

```
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '## %s - %s - SKIPPED-no-inputs - %s\n' "${TOKEN}" "${PHASE}" "$ts" \
  | bash $HOME/.claude/skills/apex/scripts/append-with-lock.sh ~/.claude/tmp/apex-workflow-improvements.md
```

No `gaps:` / `fixes-observed:` / `improvements:` / `workflow-respected:` / `token-reductions:` lines. `/apex-improve.analyze.md` recognises this sentinel and drops it pre-cluster.

If only ONE of the two inputs is missing, still emit the structured block - hypothesis-vs-reality and cross-session pattern surfacing remain valuable on partial inputs.

## Failure mode

Errors -> `~/.claude/tmp/reflector-errors.log`. Shut down silently (no main-session output).

See `apex-core.md` Conventions for trace path schema and manifest schema.
