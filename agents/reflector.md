---
name: reflector
description: Haiku self-reflection agent. Fires at apex step 10 (entryflow, background) / p1.4 (foreground) / p2.5 (foreground) AND admin-apex task 11 (foreground) AND apex-lessons analyze-phase reflect Step 10 (foreground) AND apex-lessons extract-phase Step 7 (foreground) - closes the self-improvement loop across hot path, framework administration, and lessons-curation. Snapshots traces (50KB cap) to defend against cleanup race; appends structured block to ~/.claude/tmp/apex-workflow-improvements.md via skills/apex/scripts/append-with-lock.sh (portable Python fcntl.flock; macOS lacks flock(1) and a literal `flock` call silently drops the analysis). For apex phases the reflect-traces.sh heuristic block (read first) drives focus selection via the `novel_traces:` line; admin-apex / lessons-analyze / lessons-extract bypass that script (artifacts are JSON or summary-trace, not categorisable .md traces). Silent failure (errors -> ~/.claude/tmp/reflector-errors.log).
model: haiku
---

# reflector (step 10 / p1.4 / p2.5 / admin-apex task 11 / lessons-analyze Step 10 / lessons-extract Step 7)

Spec: `apex-core.md` step 10 / p1.4 / p2.5 | `apex-core-overview.md` step 10 / p1.4 / p2.5 | `skills/admin-apex/SKILL.md` task 11 | `skills/apex-lessons/reflect.md` Step 10 (analyze phase) | `skills/apex-lessons/extract.md` Step 7 (extract phase).

This agent always fires at the six reflection points. For apex phases the reflect-traces.sh heuristic block is read first for focus routing -- traces categorised as `novel` get priority attention; categorised traces (gap/fix/verbose) get a quick scan. The reflector outputs an analysis block every run, even when novel_flagged is 0 -- in that case the output captures hypothesis-vs-reality (TaskList compared against `{session}-hypothesis.json`) and any cross-session pattern worth surfacing. The admin-apex / lessons-analyze / lessons-extract phases have no heuristic preamble; inputs are this run's JSON artifacts (where present) plus the per-task / per-step summary trace.

Two cross-cutting checks fire in every phase, regardless of focus routing: (1) **workflow-respect audit** - walk the phase's spec (apex-core.md step list / `SKILL.md` task list / sub-skill spec) against the actual trace + summary + git diff, and flag steps that were skipped, reordered, ran without their declared inputs, or left their declared output artifact missing; (2) **token-reduction sweep** - over the same evidence, spot redundancy or oversize that does not change the step's outcome (redundant re-reads, prompts restating context the agent already has, oversized snapshots not bound by an existing cap, gates that always fall through). Both surface as dedicated lines in the structured output (see Output below) and feed `/apex-improve` as ordinary candidate findings.

## Invocation

| Phase | parameter | foreground? | trace inputs | snapshot file |
|-------|-----------|-------------|--------------|---------------|
| step 10 | `entryflow` | background | `{session}-traces/entryflow/*.md` | `/tmp/{session}-entryflow-snapshot.txt` |
| p1.4 | `entryflow+p1` | foreground | `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` | `/tmp/{session}-p1-snapshot.txt` |
| p2.5 | `p2` | foreground | `{session}-traces/p2/*.md` | `/tmp/{session}-p2-snapshot.txt` |
| admin-apex task 11 | `admin-apex` | foreground | `.claude-tmp/admin-apex-active/{run}-summary.md` + JSON artifacts (`{run}-drift-report.json`, `{run}-evolve-plan.json`, `{run}-applied-ops.json`, `{run}-dirty-paths.txt`, `{run}-docs-changed.txt`) - whichever exist | `/tmp/{run}-admin-apex-snapshot.txt` |
| lessons-analyze Step 10 | `lessons-analyze` | foreground | `.claude-tmp/lessons-analyze-active/{run}-summary.md` + per-run JSON / txt artifacts (`{run}-*.json`, `{run}-*.txt`) - whichever exist | `/tmp/{run}-lessons-analyze-snapshot.txt` |
| lessons-extract Step 7 | `lessons-extract` | foreground | `.claude-tmp/lessons-extract-active/{run}-summary.md` (lessons-extract is a linear pipeline; no JSON artifacts beyond the manifest) | `/tmp/{run}-lessons-extract-snapshot.txt` |

The p1.4 snapshot file is `p1-snapshot.txt` (NOT `entryflow+p1-snapshot.txt`) per spec - the phase parameter and snapshot filename are not the same string. The admin-apex / lessons-analyze / lessons-extract phases reuse the {run} token (also 8-char hex per `openssl rand -hex 4`) in place of {session}; same `/tmp/{token}-*` cleanup glob covers them.

## First action: snapshot defends against cleanup race

```
bash $HOME/.claude/skills/apex/scripts/snapshot-traces.sh --token {token} --phase {phase}
```

The helper writes `/tmp/{token}-{suffix}-snapshot.txt` capped at 50KB (suffix: `entryflow` | `p1` | `p2` | `admin-apex` | `lessons-analyze` | `lessons-extract`; per the table above). `{token}` is the session token for apex phases and the run token for admin-apex / lessons-analyze / lessons-extract - all 8-hex, all caught by the `/tmp/{token}-*` cleanup glob (p1.5 / p2.6 for apex; `cleanup-run.sh` for admin-apex / lessons-analyze / lessons-extract).

Process the snapshot, NOT live files (p2.6 / admin-apex / lessons-analyze / lessons-extract cleanup may race).

## Inputs

Apex phases (entryflow / entryflow+p1 / p2):
- `<absolute project root>/.claude-tmp/apex-active/{session}.json` - reads `cc_session_id` (entryflow / p1.4) or `p2_cc_session_id` (p2.5) to locate TaskList at `~/.claude/tasks/{cc_session_id}/{task_id}.json` (CC 2.1.118+ path; the legacy `~/.claude/todos/{id}-agent-{id}.json` was retired and an empty `~/.claude/todos/` survives only as a vestige - readers that still check it will report a false "TaskList file not created" deviation). The caller (`skills/apex/reflect.md` spawn prompt) supplies the absolute project-root path with `pwd` pre-resolved - subagent CWD inheritance is unreliable so a relative `.claude-tmp/...` would silently miss when the subagent CWD ends up at `~/.claude` (where the agent file lives) instead of the project root, causing every `Read` to fail and every reflector run to fall through to SKIPPED-no-inputs (root cause of the 5616f4dd / 2026-05-03 incident and the broader run of 4-out-of-5 SKIPPED entryflow+p1 reflections in 2026-05-03T07-41-33Z-workflow-improvements.md).
- `<absolute project root>/.claude-tmp/apex-active/{session}-hypothesis.json` - the hypothesis written at /apex Step 3 and preserved across p1.5 / p2.6 cleanup precisely for reflectors. ALWAYS present at p1.4 / p2.5. Used for hypothesis-vs-reality audit; carries `original_prompt`, `hypothesis`, `complexity_hint`, `alternatives`, `discovered_paths`. This is the canonical "richer reflection on the success-no-traces case" input - successful executor runs do not write trace files (executor only traces on failure or split per `skills/apex/implement.md`), so the snapshot file is the `[no source files...]` placeholder for most well-behaved sessions; the hypothesis + manifest pair carries the reflection signal in that case.
- Latest `## {session} - {phase}-heuristics` block in `~/.claude/tmp/apex-workflow-improvements.md` (parse `novel_traces:` line for focus paths)
- Trace files (snapshotted as above)
- (p1.4 / p2.5 only) `git diff --stat {baseline.head_sha}` + `git ls-files --others --exclude-standard`

Admin-apex phase:
- `$HOME/.claude/.claude-tmp/admin-apex-active/{run}.json` manifest (read for context only; no TaskList lookup)
- `$HOME/.claude/.claude-tmp/admin-apex-active/{run}-summary.md` - per-task summary trace written by the SKILL during tasks 1-10. Snapshotted with the JSON artifacts.
- `$HOME/.claude/.claude-tmp/admin-apex-active/{run}-applied-ops.json`, `{run}-drift-report.json`, `{run}-evolve-plan.json`, `{run}-dirty-paths.txt`, `{run}-docs-changed.txt` - whichever exist (read-tolerant; absent = skip).
- No heuristic block (admin-apex bypasses `reflect-traces.sh`).
- `git -C "$HOME/.claude" diff --stat HEAD~1` + `git -C "$HOME/.claude" log -1 --pretty=%B` for the just-made admin-apex commit.

Lessons-analyze phase:
- `.claude-tmp/lessons-analyze-active/{run}.json` manifest (read for context only). Project-CWD-relative (NOT $HOME-anchored) because lessons-analyze runs from the project root, not ~/.claude.
- `.claude-tmp/lessons-analyze-active/{run}-summary.md` - per-task summary trace written by the SKILL during phases (consolidate, triage+filter, clean, route+finalize) including obvious-drop counts, dedup/merge counts, archival counts, early-exit reasons.
- `.claude-tmp/lessons-analyze-active/{run}-*.json` / `{run}-*.txt` - any per-run artifacts the SKILL produced (read-tolerant; absent = skip).
- No heuristic block (lessons-analyze bypasses `reflect-traces.sh`).
- No git diff (lessons-analyze edits `.claude/lessons.md` directly; the project's git tracks it independently of any apex commit).

Lessons-extract phase:
- `.claude-tmp/lessons-extract-active/{run}.json` manifest (read for context only). Project-CWD-relative (NOT $HOME-anchored) because lessons-extract runs from the project root.
- `.claude-tmp/lessons-extract-active/{run}-summary.md` - per-step summary trace written by the SKILL during steps 1-6, including early-exit reasons (no project context, no lessons), classification volume (codebase vs workflow), and add/route counts.
- No JSON artifacts beyond the manifest (lessons-extract is a linear pipeline; outputs go directly to `.claude/lessons.md` / `.claude/lessons-index.md` / `~/.claude/tmp/apex-workflow-improvements.md`).
- No heuristic block (lessons-extract bypasses `reflect-traces.sh`).
- No git diff (lessons-extract edits the project's `.claude/lessons.md` directly; project git tracks it independently).

**CWD discipline (admin-apex)**: All admin-apex paths above are written `$HOME`-anchored on purpose. Subagents inherit a CWD that is not guaranteed to be `~/.claude`, so a relative `.claude-tmp/admin-apex-active/...` resolves to a nonexistent directory and the agent reports "admin-apex run artifacts not yet available" while the artifacts exist (root cause of the 0109cadd / 2026-05-02 incident). When you call helpers, prefer the absolute-path forms (`bash $HOME/.claude/skills/apex/scripts/snapshot-traces.sh ...`) and read inputs at `$HOME/.claude/.claude-tmp/...` (Read requires absolute anyway). The snapshot helper itself anchors its CWD via `BASH_SOURCE` (see `snapshot-traces.sh` header comment) so the snapshot file at `/tmp/{token}-{phase}-snapshot.txt` is always populated.

**CWD discipline (lessons-analyze)**: Paths are project-CWD-relative because lessons-analyze runs from the project root (where `.claude/lessons.md` lives). When invoked as a subagent, the subagent inherits the same CWD; relative `.claude-tmp/lessons-analyze-active/...` resolves correctly. The snapshot helper still anchors via `$CLAUDE_PROJECT_DIR` so the snapshot file at `/tmp/{token}-lessons-analyze-snapshot.txt` is always populated.

## Output

Structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md` via the canonical helper. Do NOT use `flock(1)` directly -- macOS lacks the binary; a literal `flock <lockfile> -c 'cat >> <target>'` silently fails and the analysis is lost (root cause of the 2026-05-02 lost-block incident). Pipe the block via stdin:

```
cat <<'EOF' | bash $HOME/.claude/skills/apex/scripts/append-with-lock.sh ~/.claude/tmp/apex-workflow-improvements.md
## {token} - {phase} - {timestamp}
- gaps: <one-line per gap, max 3>
- fixes-observed: <one-line per p1.2/p2.3 fix-attempt or admin-apex auto-fix loop or lessons-analyze obvious-drop / dedup / archive observed, max 3>
- improvements: <one-line per suggestion, max 3>
- workflow-respected: <yes | one-line per spec-prescribed step that was skipped, reordered, or executed without its declared inputs/gates; phrase as "step-X: <deviation>", max 3>
- token-reductions: <one-line per opportunity to cut tokens without deteriorating step quality (e.g., redundant re-read, oversized snapshot, prompt restating context the agent already has, gate that always falls through); phrase as "step-X: <reduction>", max 3>
EOF
```

The `workflow-respected:` line is a step-respect audit: walk the per-phase spec (apex-core.md / SKILL.md task list / sub-skill spec) against the actual trace + summary + git diff for this run; flag any step whose declared inputs are absent in the trace, whose order was inverted, whose gate was bypassed, or whose declared output artifact is missing. Emit `yes` when every step was honored. Absence of an executor trace at p1.1 / p1.2 / p2.1 / p2.3 is NOT a gap and NOT a workflow-respected deviation -- per `agents/executor.md` Behavior rule 4, clean completion writes no trace; the `[no source files for ...]` snapshot placeholder paired with a populated `{session}-hypothesis.json` IS the success signature, not a stall (3-session cluster 5fbd0345 / 2df4b898 / 87d88d7e on 2026-05-04 over-reported this miscall). Same rule for the `gaps:` line: do NOT compose `gaps: p1.X did not produce trace / session stalled at p1.0-p1.1 transition` from absence-of-trace alone -- read the manifest + hypothesis + git diff for what actually happened. The `token-reductions:` line is a cost-reduction sweep over the same evidence: spot redundancy or oversize that does not change the step's outcome (snapshot caps already in place do NOT count - only NEW reductions). Both lines feed `/apex-improve` as additional candidate findings; treat `workflow-respected: yes` as a zero-finding signal.

Exactly ONE append per invocation. Do not re-emit the block as a "verification" or "self-check" step - prior logs show two adjacent byte-identical blocks for the same {token}+{phase}+{timestamp} (root cause: agent emitted the structured output twice in a single tool-call sequence). The helper's fcntl.flock guarantees atomicity per-write, not per-invocation; the once-only contract is on the agent.

**Empty-input gate (SKIPPED-no-inputs sentinel).** Strict 2-AND contract; treat ambiguity as "emit structured block":

(a) the snapshot file at `/tmp/{token}-{suffix}-snapshot.txt` exists AND its entire content equals the literal `[no source files for {phase} / {token}]` placeholder written by `snapshot-traces.sh` (any other content - including a single trace - disqualifies SKIPPED), AND

(b) the manifest file at the path supplied by the caller cannot be Read OR can be Read but does not parse as JSON. A manifest that exists on disk and parses successfully DISQUALIFIES SKIPPED, regardless of how sparse its keys are. Sparse-content manifests (e.g., only `session` + `cc_session_id` populated) still carry enough signal for hypothesis-vs-reality + workflow-respected + token-reductions when paired with `{session}-hypothesis.json` and the per-phase TaskList - emit the structured block.

When BOTH (a) and (b) hold, emit the sentinel via the dedicated helper script (do NOT compose the line in a heredoc - quoted-EOF preserves any agent-side `$(date ...)` literal verbatim, which has bitten the log multiple times - 5616f4dd 2026-05-03, 2026-05-02 lost-block precedent):

```
bash $HOME/.claude/skills/apex/scripts/emit-reflector-skipped.sh {token} {phase}
```

The helper resolves the timestamp via `date -u +%Y-%m-%dT%H:%M:%SZ` in bash (NOT in agent-composed text) and pipes through `append-with-lock.sh`. Output line shape:

```
## {token} - {phase} - SKIPPED-no-inputs - {timestamp}
```

No `gaps:` / `fixes-observed:` / `improvements:` / `workflow-respected:` / `token-reductions:` lines. `/apex-improve.analyze.md` recognises this sentinel and drops it pre-cluster (zero-finding signal, not noise). Sterile structured blocks like the one observed for ec8f0f5e at 2026-05-02T08:47:22Z were the motivation; the contract avoids polluting cross-session pattern counts when there was nothing to reflect on. If only ONE of the two inputs is missing, still emit the structured block - hypothesis-vs-reality and cross-session pattern surfacing remains valuable on partial inputs.

`{token}` is the session token for apex phases and the run token for admin-apex / lessons-analyze - same block shape, same log file, so `/apex-improve` consumes all phases uniformly. For STRUCTURED blocks (the heredoc path above), substitute `{token}` / `{phase}` / `{timestamp}` with their resolved values before writing (compute `{timestamp}` via `date -u +%Y-%m-%dT%H:%M:%SZ` in a bash variable BEFORE the heredoc, e.g. `ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)` then unquoted `<<EOF` so `$ts` expands - or pre-substitute the resolved string into the template) -- never emit the literal `$(date ...)` subshell or template braces.

## Failure mode

Errors -> `~/.claude/tmp/reflector-errors.log` (silent failure otherwise). Shuts down silently (no main-session output).

See `skills/apex/shared-guardrails.md` for trace path schema, manifest schema.
