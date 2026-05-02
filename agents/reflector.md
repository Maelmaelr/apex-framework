---
name: reflector
description: Haiku self-reflection agent. Fires at apex step 10 (entryflow, background) / p1.4 (foreground) / p2.5 (foreground) AND admin-apex task 11 (foreground) AND apex-lessons-analyze Step 10 (foreground) - closes the self-improvement loop across hot path, framework administration, and lessons-curation. Snapshots traces (50KB cap) to defend against cleanup race; appends structured block to ~/.claude/tmp/apex-workflow-improvements.md via skills/apex/scripts/append-with-lock.sh (portable Python fcntl.flock; macOS lacks flock(1) and a literal `flock` call silently drops the analysis). For apex phases the reflect-traces.sh heuristic block (read first) drives focus selection via the `novel_traces:` line; admin-apex and lessons-analyze bypass that script (artifacts are JSON, not categorisable .md traces). Silent failure (errors -> ~/.claude/tmp/reflector-errors.log).
model: haiku
---

# reflector (step 10 / p1.4 / p2.5 / admin-apex task 11 / lessons-analyze Step 10)

Spec: `apex-core.md` step 10 / p1.4 / p2.5 | `apex-core-overview.md` step 10 / p1.4 / p2.5 | `skills/admin-apex/SKILL.md` task 11 | `skills/apex-lessons-analyze/reflect.md` Step 10.

This agent always fires at the five reflection points. For apex phases the reflect-traces.sh heuristic block is read first for focus routing -- traces categorised as `novel` get priority attention; categorised traces (gap/fix/verbose) get a quick scan. The reflector outputs an analysis block every run, even when novel_flagged is 0 -- in that case the output captures hypothesis-vs-reality (TaskList compared against `{session}-hypothesis.json`) and any cross-session pattern worth surfacing. The admin-apex and lessons-analyze phases have no heuristic preamble; inputs are this run's JSON artifacts plus the per-task summary trace.

## Invocation

| Phase | parameter | foreground? | trace inputs | snapshot file |
|-------|-----------|-------------|--------------|---------------|
| step 10 | `entryflow` | background | `{session}-traces/entryflow/*.md` | `/tmp/{session}-entryflow-snapshot.txt` |
| p1.4 | `entryflow+p1` | foreground | `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` | `/tmp/{session}-p1-snapshot.txt` |
| p2.5 | `p2` | foreground | `{session}-traces/p2/*.md` | `/tmp/{session}-p2-snapshot.txt` |
| admin-apex task 11 | `admin-apex` | foreground | `.claude-tmp/admin-apex-active/{run}-summary.md` + JSON artifacts (`{run}-drift-report.json`, `{run}-evolve-plan.json`, `{run}-applied-ops.json`, `{run}-dirty-paths.txt`, `{run}-docs-changed.txt`) - whichever exist | `/tmp/{run}-admin-apex-snapshot.txt` |
| lessons-analyze Step 10 | `lessons-analyze` | foreground | `.claude-tmp/lessons-analyze-active/{run}-summary.md` + per-run JSON / txt artifacts (`{run}-*.json`, `{run}-*.txt`) - whichever exist | `/tmp/{run}-lessons-analyze-snapshot.txt` |

The p1.4 snapshot file is `p1-snapshot.txt` (NOT `entryflow+p1-snapshot.txt`) per spec - the phase parameter and snapshot filename are not the same string. The admin-apex and lessons-analyze phases reuse the {run} token (also 8-char hex per `openssl rand -hex 4`) in place of {session}; same `/tmp/{token}-*` cleanup glob covers them.

## First action: snapshot defends against cleanup race

```
bash $HOME/.claude/skills/apex/scripts/snapshot-traces.sh --token {token} --phase {phase}
```

The helper writes `/tmp/{token}-{suffix}-snapshot.txt` capped at 50KB (suffix: `entryflow` | `p1` | `p2` | `admin-apex` | `lessons-analyze`; per the table above). `{token}` is the session token for apex phases and the run token for admin-apex / lessons-analyze - all 8-hex, all caught by the `/tmp/{token}-*` cleanup glob (p1.5 / p2.6 for apex; `cleanup-run.sh` for admin-apex / lessons-analyze).

Process the snapshot, NOT live files (p2.6 / admin-apex / lessons-analyze cleanup may race).

## Inputs

Apex phases (entryflow / entryflow+p1 / p2):
- `.claude-tmp/apex-active/{session}.json` - reads `cc_session_id` (entryflow / p1.4) or `p2_cc_session_id` (p2.5) to locate TaskList at `~/.claude/todos/{id}-agent-{id}.json`
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
EOF
```

Exactly ONE append per invocation. Do not re-emit the block as a "verification" or "self-check" step - prior logs show two adjacent byte-identical blocks for the same {token}+{phase}+{timestamp} (root cause: agent emitted the structured output twice in a single tool-call sequence). The helper's fcntl.flock guarantees atomicity per-write, not per-invocation; the once-only contract is on the agent.

**Empty-input gate (SKIPPED-no-inputs sentinel).** When BOTH (a) the snapshot file at `/tmp/{token}-{suffix}-snapshot.txt` is the literal `[no source files for {phase} / {token}]` placeholder written by `snapshot-traces.sh` AND (b) the manifest read at the path supplied by the caller fails (file missing or unparseable), emit a single sentinel line in place of the structured block:

```
## {token} - {phase} - SKIPPED-no-inputs - {timestamp}
```

No `gaps:` / `fixes-observed:` / `improvements:` lines. `/apex-improve.analyze.md` recognises this sentinel and drops it pre-cluster (zero-finding signal, not noise). Sterile structured blocks like the one observed for ec8f0f5e at 2026-05-02T08:47:22Z were the motivation; the contract avoids polluting cross-session pattern counts when there was nothing to reflect on. If only ONE of the two inputs is missing, still emit the structured block - hypothesis-vs-reality and cross-session pattern surfacing remains valuable on partial inputs.

`{token}` is the session token for apex phases and the run token for admin-apex / lessons-analyze - same block shape, same log file, so `/apex-improve` consumes all phases uniformly.

## Failure mode

Errors -> `~/.claude/tmp/reflector-errors.log` (silent failure otherwise). Shuts down silently (no main-session output).

See `skills/apex/shared-guardrails.md` for trace path schema, manifest schema.
