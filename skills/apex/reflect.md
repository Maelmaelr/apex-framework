---
name: reflect
description: step 10 / p1.4 / p2.5 self-reflect orchestrator. Runs scripts/reflect-traces.sh to append a heuristics block, parses novel_flagged from that block, then conditionally spawns agents/reflector.md (Haiku) - background at step 10 (entryflow), foreground at p1.4 (entryflow+p1) / p2.5 (p2). Silent on novel_flagged == 0; reflector self-silences on errors.
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

`reflect-traces.sh` is the script-first heuristic pass. It always exits 0 (best-effort contract per spec) and always appends a block - even when every count is zero - so step 2 can read `novel_flagged` unconditionally.

```
case "$PHASE" in
  entryflow|entryflow+p1|p2) ;;
  *) echo "reflect: invalid --phase '$PHASE' (expected entryflow|entryflow+p1|p2)" >&2 ; exit 2 ;;
esac

bash $HOME/.claude/skills/apex/scripts/reflect-traces.sh \
  --session {session} --phase "$PHASE"
```

The script appends one block to `~/.claude/tmp/apex-workflow-improvements.md` under `flock ~/.claude/tmp/apex-workflow-improvements.md.lock`:

```
## {session} - {phase}-heuristics - {timestamp}
- gap_signals: <count>
- fix_attempts: <count>
- verbose_traces: <count>
- novel_flagged: <count>
- novel_traces: <comma-separated trace paths, max 5>
```

## Step 2: Parse novel_flagged from the latest block

The reflector agent fires only when `novel_flagged >= 1`. Read the LAST block matching this session + phase (a previous re-run on exit-2 may have appended an older block) and pull the count.

The block header is matched as a LITERAL STRING (not a regex) - the `+` in `entryflow+p1-heuristics` is a regex metacharacter and `awk $0 ~ hdr` would mis-match it. Use `index($0, hdr) == 1` and pass the header via `ENVIRON` so awk treats it as plain text.

```
target="$HOME/.claude/tmp/apex-workflow-improvements.md"
[[ -f "$target" ]] || { echo "reflect: heuristics file missing; skipping reflector" >&2 ; exit 0 ; }

# Last matching block for {session}+{phase}. nf reset implicitly on each new
# matching header so the END picks up the latest. Header line is consumed by
# `next` to avoid the closing branch firing on the same record.
novel=$(SESSION={session} PHASE="$PHASE" awk '
  BEGIN { hdr = "## " ENVIRON["SESSION"] " - " ENVIRON["PHASE"] "-heuristics"; nf = 0 }
  index($0, hdr) == 1 { in_block = 1; next }
  in_block && /^- novel_flagged:/ { nf = $3 }
  in_block && /^## / { in_block = 0 }
  END { print nf+0 }
' "$target")

if (( novel < 1 )); then
  # Gate closed: heuristics covered everything (or nothing matched). Silent
  # skip per spec - this is the common case.
  exit 0
fi
```

If `novel_flagged >= 1`, proceed to step 3.

## Step 3: Conditionally spawn agents/reflector.md (Haiku)

Foreground vs background is per the table above; choose the spawn modality at orchestrator level (`run_in_background: true` for `--phase entryflow`, default foreground for `entryflow+p1` and `p2`). One Agent tool call, model = haiku, no parallel sibling spawns - this is a single-agent gate.

### Spawn-prompt template

Substitute `{session}`, `{phase}`, `{snapshot_suffix}` (see table: `entryflow` | `p1` | `p2`), `{manifest_field}` (`cc_session_id` for entryflow / entryflow+p1, `p2_cc_session_id` for p2).

```
You are agents/reflector.md. Read it at $HOME/.claude/agents/reflector.md and follow it.

Session: {session}
Phase:   {phase}                 # entryflow | entryflow+p1 | p2
Manifest: .claude-tmp/apex-active/{session}.json
  - read {manifest_field} from this file; load the TaskList at
    ~/.claude/todos/<id>-agent-<id>.json where <id> is that field's value.

Heuristics block (already appended by scripts/reflect-traces.sh):
  ~/.claude/tmp/apex-workflow-improvements.md
  - parse the LATEST `## {session} - {phase}-heuristics - <ts>` block
  - the `novel_traces:` line lists the trace paths to focus on (max 5)

First action - snapshot defends against the p1.5 / p2.6 cleanup race
(cap 50KB for Haiku context bound). Use the trace globs that match {phase}:
  entryflow      -> .claude-tmp/apex-active/{session}-traces/entryflow/*.md
  entryflow+p1   -> .claude-tmp/apex-active/{session}-traces/entryflow/*.md
                    .claude-tmp/apex-active/{session}-traces/p1/*.md
  p2             -> .claude-tmp/apex-active/{session}-traces/p2/*.md

  TOTAL=$(cat <trace globs> | wc -c)
  N=$(ls <trace globs> | wc -l)
  cat <trace globs> | head -c 51200 > /tmp/{session}-{snapshot_suffix}-snapshot.txt
  [ "$TOTAL" -gt 51200 ] && echo "[snapshot truncated, $N traces total]" >> /tmp/{session}-{snapshot_suffix}-snapshot.txt

Then process the snapshot file - NOT the live trace files (cleanup may race).

Additional inputs for entryflow+p1 / p2 (omit for entryflow):
  - git diff --stat <baseline.head_sha>     (head_sha from {session}-baseline.json)
  - git ls-files --others --exclude-standard

Output: structured append (NO prose) to
  ~/.claude/tmp/apex-workflow-improvements.md
under `flock ~/.claude/tmp/apex-workflow-improvements.md.lock`:

  ## {session} - {phase} - <timestamp>
  - gaps: <one-line per gap, max 3>
  - fixes-observed: <one-line per p1.2/p2.3 fix-attempt observed in traces, max 3>
  - improvements: <one-line per suggestion, max 3>

Errors -> ~/.claude/tmp/reflector-errors.log (silent failure otherwise).
Shut down silently (no main-session output).
```

## Foreground vs background

| Phase | Modality | Why |
|-------|----------|-----|
| `entryflow` (step 10) | background (`run_in_background: true`) | step 10 is mid-pipeline; orchestrator continues into p2.0a/b/c without waiting on the reflector |
| `entryflow+p1` (p1.4) | foreground | end-of-session in main mode; p1.5 cleanup blocks on p1.4 explicitly so there is nothing to overlap |
| `p2` (p2.5) | foreground | end-of-session in Path 2; p2.6 cleanup blocks on p2.5 explicitly for the same reason |

## Fail-silent contract (whole step)

- `reflect-traces.sh` failure -> already best-effort (exits 0 with stderr); orchestrator proceeds to step 2 unconditionally.
- Heuristics file unreadable / missing block / parse failure -> silent skip (gate closed).
- `novel_flagged == 0` -> silent skip (this is the common case).
- Reflector agent failure -> agent itself fail-silents to `~/.claude/tmp/reflector-errors.log` per `agents/reflector.md` contract; returns success to the orchestrator so the chain (p1.5 / p2.6) is NOT blocked.

This is intentional: reflection is a workflow-improvement signal, not a correctness gate. Hard-failing here would block cleanup and the inline summary for cosmetic gains.

## Cleanup

`reflect.md` produces no session-keyed artifacts of its own. The `/tmp/{session}-{suffix}-snapshot.txt` files are written by the reflector agent and removed by the `/tmp/{session}-*` glob in `cleanup-session.sh` (p1.5 / p2.6) - this skill writes nothing under `/tmp` directly. The heuristics block in `~/.claude/tmp/apex-workflow-improvements.md` is intentionally NOT cleaned (it persists across sessions for cross-session pattern analysis).

## What this skill does NOT do

- Does NOT decide what is novel - `reflect-traces.sh` does (gap_signals / fix_attempts / verbose_traces / everything else).
- Does NOT write to `~/.claude/tmp/apex-workflow-improvements.md` directly - the script and the agent do, each under the shared `flock`.
- Does NOT consume `screened-{session}.json` / findings - reflection is post-implementation, not implementation.
- Does NOT extend scope - the reflector reads/writes only inside `~/.claude/tmp/`, `/tmp/`, and `.claude-tmp/apex-active/{session}-traces/` (all standard safety paths).
- Does NOT block the chain on failure - fail-silent per the contract above.

See `agents/reflector.md` for the agent's input/output contract; `scripts/reflect-traces.sh` for the heuristic categorisation; `shared-guardrails.md` for safety paths, manifest schema (`cc_session_id` vs `p2_cc_session_id`), trace path schema.
