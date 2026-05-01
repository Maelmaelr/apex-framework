---
name: reflect
description: step 10 / p1.4 / p2.5 self-reflect orchestrator. Runs scripts/reflect-traces.sh to append a heuristics block (focus-routing input), then unconditionally spawns agents/reflector.md (Haiku) - background at step 10 (entryflow), foreground at p1.4 (entryflow+p1) / p2.5 (p2). The novel_traces line in the heuristics block drives where the reflector focuses, but no longer gates whether it runs. Reflector self-silences on errors.
---

# reflect (step 10 / p1.4 / p2.5)

Spec: `apex-core.md` step 10 / p1.4 / p2.5 | `apex-core-overview.md` Reflector | `agents/reflector.md` invocation table.

Single skill body, three invocation contexts. The caller passes `--phase entryflow` (step 10 entry-flow, Path 2 only), `--phase entryflow+p1` (main-mode p1.4), or `--phase p2` (central Path 2 p2.5); session token via `--session`. Phase choice drives trace inputs, snapshot filename, foreground/background, and which manifest field (`cc_session_id` vs `p2_cc_session_id`) the reflector uses to locate its TaskList.

## Invocation contexts

| Caller | Phase arg | Foreground? | Trace inputs (snapshot) | Snapshot file | Manifest field |
|--------|-----------|-------------|--------------------------|---------------|----------------|
| `SKILL.md` step 10 (Path 2 only) | `--phase entryflow` | background | `{session}-traces/entryflow/*.md` | `/tmp/{session}-entryflow-snapshot.txt` | `cc_session_id` |
| `p1.md` p1.4 (main mode only) | `--phase entryflow+p1` | foreground | `{session}-traces/entryflow/*.md` + `{session}-traces/p1/*.md` | `/tmp/{session}-p1-snapshot.txt` | `cc_session_id` |
| `p2.md` p2.5 (after p2.4) | `--phase p2` | foreground | `{session}-traces/p2/*.md` | `/tmp/{session}-p2-snapshot.txt` | `p2_cc_session_id` |

The p1.4 snapshot suffix is `p1` (NOT `entryflow+p1`) per `agents/reflector.md` - the phase parameter and the snapshot filename intentionally differ.

Teammate mode (`p1.md --teammate`) skips this skill entirely - central p2.5 owns Path 2 reflection (per `apex-core.md` Teammate-mode trim).

## Step 1: Run the heuristics script

`reflect-traces.sh` is best-effort: always exits 0, always appends a block (even when every count is zero) so the reflector spawn prompt can point at the latest `novel_traces:` paths. The `novel_flagged` count is informational only since v1.4.0 (no longer a gate); proceed unconditionally to step 2.

```
case "$PHASE" in
  entryflow|entryflow+p1|p2) ;;
  *) echo "reflect: invalid --phase '$PHASE' (expected entryflow|entryflow+p1|p2)" >&2 ; exit 2 ;;
esac

bash $HOME/.claude/skills/apex/scripts/reflect-traces.sh \
  --session {session} --phase "$PHASE"
```

Appended block (under `flock ~/.claude/tmp/apex-workflow-improvements.md.lock`):

```
## {session} - {phase}-heuristics - {timestamp}
- gap_signals: <count>
- fix_attempts: <count>
- verbose_traces: <count>
- novel_flagged: <count>
- novel_traces: <comma-separated trace paths, max 5>
```

If the heuristics file is missing or the block is unparseable, the reflector still runs; the spawn prompt simply omits the `novel_traces:` focus list and points at the live trace globs.

## Step 2: Spawn agents/reflector.md (Haiku)

Foreground vs background is per the table above; choose the spawn modality at orchestrator level (`run_in_background: true` for `--phase entryflow`, default foreground for `entryflow+p1` and `p2`). One Agent tool call, model = haiku, no parallel sibling spawns - this is a single-agent gate.

### Spawn-prompt template

Substitute `{session}`, `{phase}` (`entryflow` | `entryflow+p1` | `p2`), and `{snapshot_suffix}` (`entryflow` | `p1` | `p2` per the invocation-contexts table).

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and follow it.

Session:  {session}
Phase:    {phase}             # entryflow | entryflow+p1 | p2
Manifest: .claude-tmp/apex-active/{session}.json
Snapshot: /tmp/{session}-{snapshot_suffix}-snapshot.txt
```

## Fail-silent contract

Reflection is an improvement signal, not a correctness gate -- hard-failing here would block cleanup for cosmetic gains. Both `reflect-traces.sh` and the reflector agent self-silence (errors -> `~/.claude/tmp/reflector-errors.log`); the chain (p1.5 / p2.6) is never blocked. Foreground vs background is per the "Invocation contexts" table above; no other modality decision lives here.

## Cleanup

`reflect.md` produces no session-keyed artifacts of its own. The `/tmp/{session}-{suffix}-snapshot.txt` files are written by the reflector agent and removed by the `/tmp/{session}-*` glob in `cleanup-session.sh` (p1.5 / p2.6) - this skill writes nothing under `/tmp` directly. The heuristics block in `~/.claude/tmp/apex-workflow-improvements.md` is intentionally NOT cleaned (it persists across sessions for cross-session pattern analysis).

## What this skill does NOT do

- Does NOT decide what is novel - `reflect-traces.sh` does (gap_signals / fix_attempts / verbose_traces / everything else).
- Does NOT write to `~/.claude/tmp/apex-workflow-improvements.md` directly - the script and the agent do, each under the shared `flock`.
- Does NOT consume `screened-{session}.json` / findings - reflection is post-implementation, not implementation.
- Does NOT extend scope - the reflector reads/writes only inside `~/.claude/tmp/`, `/tmp/`, and `.claude-tmp/apex-active/{session}-traces/` (all standard safety paths).
- Does NOT block the chain on failure - fail-silent per the contract above.

See `agents/reflector.md` for the agent's input/output contract; `scripts/reflect-traces.sh` for the heuristic categorisation; `shared-guardrails.md` for safety paths, manifest schema (`cc_session_id` vs `p2_cc_session_id`), trace path schema.
