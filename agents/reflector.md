---
name: reflector
description: Haiku self-reflection agent. Always fires at step 10 (entryflow, background) / p1.4 (foreground) / p2.5 (foreground). Snapshots traces (50KB cap) to defend against cleanup race; appends structured block to ~/.claude/tmp/apex-workflow-improvements.md under flock. The reflect-traces.sh heuristic block (read first) drives focus selection via the `novel_traces:` line, but no longer gates whether this agent runs. Silent failure (errors -> ~/.claude/tmp/reflector-errors.log).
model: haiku
---

# reflector (step 10 / p1.4 / p2.5)

Spec: `apex-core.md` step 10 / p1.4 / p2.5 | `apex-core-overview.md` Reflector.

This agent always fires at the three reflection points (since apex framework v1.4.0). The reflect-traces.sh heuristic block is still read first for focus routing -- traces categorised as `novel` get priority attention; categorised traces (gap/fix/verbose) get a quick scan. The reflector outputs an analysis block every run, even when novel_flagged is 0 -- in that case the output captures hypothesis-vs-reality (TaskList compared against `{session}-hypothesis.json`) and any cross-session pattern worth surfacing.

## Invocation

| Phase | parameter | foreground? | trace inputs | snapshot file |
|-------|-----------|-------------|--------------|---------------|
| step 10 | `entryflow` | background | `{session}-traces/entryflow/*.md` | `/tmp/{session}-entryflow-snapshot.txt` |
| p1.4 | `entryflow+p1` | foreground | `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` | `/tmp/{session}-p1-snapshot.txt` |
| p2.5 | `p2` | foreground | `{session}-traces/p2/*.md` | `/tmp/{session}-p2-snapshot.txt` |

The p1.4 snapshot file is `p1-snapshot.txt` (NOT `entryflow+p1-snapshot.txt`) per spec - the phase parameter and snapshot filename are not the same string.

## First action: snapshot defends against cleanup race

```
TOTAL=$(cat <trace globs> | wc -c)
N=$(ls <trace globs> | wc -l)
cat <trace globs> | head -c 51200 > /tmp/{session}-<snapshot-suffix>-snapshot.txt
[ "$TOTAL" -gt 51200 ] && echo "[snapshot truncated, $N traces total]" >> /tmp/{session}-<snapshot-suffix>-snapshot.txt
```

`<snapshot-suffix>` is `entryflow` for step 10, `p1` for p1.4, `p2` for p2.5 - matches the suffix in the table above. All three are caught by the `/tmp/{session}-*` cleanup glob in p1.5 / p2.6.

Process snapshot, NOT live files (p2.6 cleanup may race).

## Inputs

- `.claude-tmp/apex-active/{session}.json` - reads `cc_session_id` (entryflow / p1.4) or `p2_cc_session_id` (p2.5) to locate TaskList at `~/.claude/todos/{id}-agent-{id}.json`
- Latest `## {session} - {phase}-heuristics` block in `~/.claude/tmp/apex-workflow-improvements.md` (parse `novel_traces:` line for focus paths)
- Trace files (snapshotted as above)
- (p1.4 / p2.5 only) `git diff --stat {baseline.head_sha}` + `git ls-files --others --exclude-standard`

## Output

Structured append (no prose) to `~/.claude/tmp/apex-workflow-improvements.md` under `flock ~/.claude/tmp/apex-workflow-improvements.md.lock`:

```
## {session} - {phase} - {timestamp}
- gaps: <one-line per gap, max 3>
- fixes-observed: <one-line per p1.2/p2.3 fix-attempt observed in traces, max 3>
- improvements: <one-line per suggestion, max 3>
```

## Failure mode

Errors -> `~/.claude/tmp/reflector-errors.log` (silent failure otherwise). Shuts down silently (no main-session output).

See `skills/apex/shared-guardrails.md` for trace path schema, manifest schema.
