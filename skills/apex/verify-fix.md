---
name: verify-fix
description: p1.2 / p2.3 verify (lint/build) + fix-attempt orchestration. Runs scripts/verify-build.sh; on non-zero exit, spawns agents/executor.md fix-attempts capped at 3 per a {phase}-keyed fix-attempts counter ({session}-fix-attempts-main.json for p1.2, {session}-fix-attempts-p2.json for p2.3). Trace path {session}-traces/{p1|p2}/fix-{attempt-N}.md.
---

# verify-fix (p1.2 / p2.3)

Spec: `apex-core.md` p1.2 / p2.3 | `apex-core-overview.md` p1.2 / p2.3.

Single skill body, two invocation contexts. The caller passes `--phase p1` (main-mode p1.2) or `--phase p2` (central Path 2 p2.3); everything else is identical.

## Invocation contexts

| Caller | Phase arg | Counter context | Trace dir |
|--------|-----------|-----------------|-----------|
| `p1.md` p1.2 (main mode only) | `--phase p1` | `main` | `p1/` |
| `p2.md` p2.3 (after teammate shutdown) | `--phase p2` | `p2` | `p2/` |

Teammate mode (`p1.md --teammate`) skips this skill entirely - central p2.3 absorbs any teammate-introduced breakage into its own 3-attempt cap (per `apex-core.md` Teammate-mode trim).

## Step 1: Resolve paths from `--phase`

```
case "$PHASE" in
  p1)  CTX=main ; TRACE_DIR=".claude-tmp/apex-active/{session}-traces/p1" ;;
  p2)  CTX=p2   ; TRACE_DIR=".claude-tmp/apex-active/{session}-traces/p2" ;;
  *)   echo "verify-fix: invalid --phase '$PHASE' (expected p1|p2)" >&2 ; exit 2 ;;
esac
COUNTER=".claude-tmp/apex-active/{session}-fix-attempts-${CTX}.json"
ERRORS_FILE=".claude-tmp/apex-active/{session}-verify-errors.txt"
mkdir -p "$TRACE_DIR"
```

## Step 2: Verify -> fix loop (cap = 3)

```
MAX=3

# Load counter once (recovery from a prior aborted session); in-memory thereafter.
count=$(PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 - "$COUNTER" <<'PY'
import sys
from _validate import consumer_load
data = consumer_load(sys.argv[1], "fix-attempts") or {"count": 0}
print(data.get("count", 0))
PY
)

while :; do
  # 2a. Run the verifier. Exit 0 -> clean; non-zero -> errors written to ERRORS_FILE.
  if bash $HOME/.claude/skills/apex/scripts/verify-build.sh --session {session}; then
    break
  fi

  # 2b. Cap check BEFORE spawning the next attempt.
  if (( count >= MAX )); then
    echo "verify-fix: cap reached ($count/$MAX); aborting" >&2
    # Caller (p1.md / p2.md) runs session-end-hook.sh per shared-guardrails.md
    # "Mid-/apex abort cleanup"; verify-fix returns non-zero to route the chain.
    exit 1
  fi

  # 2c. Spawn executor for this attempt (see "Executor spawn prompt" below).
  attempt=$(( count + 1 ))
  trace="$TRACE_DIR/fix-${attempt}.md"
  # spawn agents/executor.md (Sonnet) with the prompt template below

  # 2d. Persist counter (producer-validates). datetime.timezone.utc for Python 3.2+ portability.
  count=$attempt
  PYTHONPATH="$HOME/.claude/skills/apex/scripts" python3 - "$COUNTER" "$count" "$ERRORS_FILE" <<'PY'
import json, sys
import datetime
from _validate import producer_validate, ValidationError
counter_path, count_str, errors_path = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "count": int(count_str),
    "last_attempt_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "last_errors_path": errors_path,
}
try:
    producer_validate(data, "fix-attempts")
except ValidationError as e:
    print(f"verify-fix: counter producer-validate failed: {e}", file=sys.stderr)
    sys.exit(1)
with open(counter_path, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY
done

# Loop exited via `break` -> verify came back clean; chain proceeds to p1.3 / p2.4.
exit 0
```

## Executor spawn prompt (per attempt)

```
You are agents/executor.md. Read it at $HOME/.claude/agents/executor.md and follow it.

Context: {p1.2 | p2.3} fix-attempt {N} of 3
Session: {session}

Errors to fix (verify-build.sh output):
<contents of {session}-verify-errors.txt -- read inline; if > ~200 lines, head/tail and note truncation>

Trace path on failure or split:
.claude-tmp/apex-active/{session}-traces/{p1|p2}/fix-{N}.md

Active scope (allowed_files):
.claude-tmp/apex-active/{session}-main-scope.json

Hooks active:
- scope-check (PreToolUse Edit/Write/MultiEdit/NotebookEdit) - resolved via {session}-scopes/{cc_session_id}.txt pointer
- file-health (PreToolUse Edit/Write) - split file > 400 lines before adding > 10 lines

Goal: fix the lint/build errors only. Do NOT add features, refactor unrelated code, or expand scope.
Return one-line summary; write trace ONLY on failure or split decision.
```

The errors file is the ONLY input the fixer needs; do NOT pass per-task slice descriptions or findings (those belong to p1.1 implement, not p1.2 fix).

## Cap-reached abort path

When the counter hits 3 and the next verify still fails:
1. `verify-fix` exits non-zero.
2. The caller (`p1.md` for p1.2 / `p2.md` for p2.3) surfaces the contents of `{session}-verify-errors.txt` to the user (truncate to ~50 lines if larger; full file remains on disk).
3. The caller runs `scripts/session-end-hook.sh {session}` inline per `shared-guardrails.md` "Mid-/apex abort cleanup".
4. No further chain steps run (p1.3+ / p2.4+ are skipped).

The counter and errors file are cleaned up by `cleanup-session.sh` in the success path (p1.5 / p2.6) and by `session-end-hook.sh` in the abort path.

## What this skill does NOT do

- Does NOT decide what to fix - the executor does, with the errors file as input.
- Does NOT consult `screened-{session}.json` / findings - p1.2 / p2.3 are recovery, not implementation.
- Does NOT extend scope - the executor is pinned to `{session}-main-scope.json` by the scope-check hook; if a fix would require touching out-of-scope code, the executor reports failure (which counts toward the cap) and the abort path surfaces the issue to the user.
- Does NOT tail / commit / learn - those are p1.3 / p2.4.

See `agents/executor.md` for trace structure and behavior contract; `scripts/verify-build.sh` for project-type detection and the errors-file format; `shared-guardrails.md` for safety paths, scope-check, JSON Schema validation.
