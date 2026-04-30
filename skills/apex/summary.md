---
name: summary
description: p1.6 / p2.7 inline summary. Single skill body, three invocation contexts (main p1.6, teammate p1.6, p2.7). Reads `{session}-hypothesis.json` (main) or `{session}-{teammate-id}-task.md` (teammate); emits original-prompt summary + hypothesis-vs-reality + short executive summary; removes hypothesis.json on success in main contexts (teammate is a no-op - p2.6 cleanup owns the task.md).
---

# summary (p1.6 / p2.7)

Spec: `apex-core.md` p1.6 / Teammate-mode trim p1.6 / p2.7 | `apex-core-overview.md` Path 1 p1.6 / Path 2 p2.7.

Single skill body, three invocation contexts. The caller passes `--phase p1` (main-mode p1.6), `--phase teammate` (teammate-mode p1.6 under Path 2), or `--phase p2` (Path 2 p2.7); session token via `--session`; teammate id via `--teammate-id` (required only when `--phase teammate`). Phase choice drives input artifact, output sections, and whether the hypothesis file is removed at exit.

Run inline by the host orchestrator (NOT a subagent). The output is the user-facing summary - the final main-session message before the chain ends.

## Invocation contexts

| Caller | Phase arg | Input artifact | Output sections | Hypothesis removed? |
|--------|-----------|----------------|-----------------|---------------------|
| `p1.md` p1.6 (main mode) | `--phase p1` | `{session}-hypothesis.json` | original prompt summary + hypothesis vs reality + executive summary | yes |
| `p1.md` p1.6 (teammate mode) | `--phase teammate` | `{session}-{teammate-id}-task.md` | task summary + executive summary (reported back to main orchestrator) | no (p2.6 cleanup owns) |
| `p2.md` p2.7 | `--phase p2` | `{session}-hypothesis.json` | original prompt summary + hypothesis vs reality + executive summary | yes |

Main p1.6 and p2.7 are functionally identical - the phase parameter is preserved for trace/log clarity and forward-compat.

## Step 1: Read the input artifact

```
case "$PHASE" in
  p1|p2|teammate) ;;
  *) echo "summary: invalid --phase '$PHASE' (expected p1|teammate|p2)" >&2 ; exit 2 ;;
esac

case "$PHASE" in
  p1|p2)
    input=".claude-tmp/apex-active/{session}-hypothesis.json"
    ;;
  teammate)
    [[ -z "$TEAMMATE_ID" ]] && { echo "summary: --teammate-id required for --phase teammate" >&2 ; exit 2 ; }
    input=".claude-tmp/apex-active/{session}-{teammate-id}-task.md"
    ;;
esac
```

Missing input is a soft error: emit a one-line user-facing notice ("summary input absent: <path>") and exit 0. This protects against the edge cases where p1.5 / p2.6 cleanup ran early due to a hook race or where the teammate task.md was never written by `teammates.md` at p2.1. The chain has already done its work; failing the summary step would only surface a confusing error to the user.

### Main p1 / p2 input shape

`{session}-hypothesis.json` conforms to `schemas/hypothesis.schema.json`:

```
{
  "original_prompt": "<verbatim user prompt>",
  "hypothesis":      "<orchestrator's working interpretation, 1-2 sentences>",
  "complexity_hint": "low" | "medium" | "high",
  "alternatives":    [{"interpretation": "...", "status": "kept" | "rejected", "reason": "..."}, ...]
}
```

Consumer-validate via `_validate.py` (treat invalid as missing and fall through to the soft-error path):

```
PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 -c "
import sys, json
from _validate import consumer_load
d = consumer_load('$input', 'hypothesis')
if d is None:
    sys.exit(1)
print(json.dumps(d))
"
```

### Teammate input shape

`{session}-{teammate-id}-task.md` is plain markdown - the per-teammate task description written by `teammates.md` at p2.1 (sourced from the planner's per-teammate task description at p2.0b). No schema; treat the file content as opaque prose.

## Step 2: Emit the summary

### Main p1 / p2 (`--phase p1` or `--phase p2`)

Three sections, in order:

1. **Original prompt summary** - paraphrase `original_prompt` in one or two sentences. Do NOT quote the verbatim prompt back at the user; the goal is a compact restatement, not an echo.
2. **Hypothesis vs reality** - compare `hypothesis` (the orchestrator's working interpretation at step 3) against what actually shipped. Surface gaps spotted: scope expansion, scope contraction, unexpected files touched, design choices that diverged from the hypothesis. Pull from the working memory of the chain (TaskList state, executor traces, verify outcome) - do NOT re-read source files. One short bullet per gap, max 3 bullets.
3. **Short executive summary** - one paragraph (3-5 sentences). What was done, what verifications passed, what was committed. Reference key files by path.

Keep total length under ~25 lines. The summary is the user's last view of the session - dense and skimmable beats exhaustive.

### Teammate (`--phase teammate`)

Two sections, in order:

1. **Task summary** - one or two sentences restating what the teammate's task description (from `task.md`) asked for, framed as "you asked me to ..." - this is the teammate reporting back to the main orchestrator.
2. **Short executive summary** - one paragraph (3-5 sentences) of what the teammate actually did. Files touched (within teammate scope), polish actions, anything escalated to the main orchestrator (peer messages, blocked points).

Output goes back to the main orchestrator (which is consuming teammate p1.6 output as part of its p2.1 monitoring loop), NOT to the end user. Tone is concise and machine-readable; the main orchestrator reformats for the user at p2.7.

## Step 3: Cleanup hypothesis file (main contexts only)

```
case "$PHASE" in
  p1|p2)
    rm -f ".claude-tmp/apex-active/{session}-hypothesis.json" 2>/dev/null || true
    ;;
  teammate)
    # No-op: p2.6 cleanup owns {session}-{teammate-id}-task.md per spec
    ;;
esac
```

Removal is best-effort. `session-end-hook.sh` is the idempotent fallback if this step fails or is bypassed (e.g., session crashes between Step 2 and Step 3).

## Fail-silent contract

- Input artifact missing -> one-line notice + exit 0 (the chain has already done its work; do not block).
- Input artifact invalid (consumer-validate failure on hypothesis.json) -> treat as missing per `shared-guardrails.md` JSON Schema validation.
- Hypothesis removal failure -> silent (`session-end-hook.sh` cleans up on session end).

The summary is the last step in the chain - hard-failing here only surfaces a confusing error to the user after the actual work has shipped.

## What this skill does NOT do

- Does NOT re-verify the build / lint - that ran at p1.2 (main) or p2.3 (Path 2).
- Does NOT re-read source files - the summary draws from the orchestrator's working memory (TaskList state, traces produced earlier in the chain, verify outcome).
- Does NOT update lessons / docs / git - those are p1.3 / p2.4 (tail).
- Does NOT extend scope - this skill writes nothing under the project tree; the only file it touches is the hypothesis file under `.claude-tmp/apex-active/` (a standard safety path).

See `schemas/hypothesis.schema.json` for the input shape; `apex-core.md` step 3 for how the hypothesis is produced upstream; `shared-guardrails.md` for safety paths and JSON Schema validation.
