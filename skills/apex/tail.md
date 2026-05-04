---
name: tail
description: p1.3 / p2.4 tail-step orchestrator. Runs scripts/detect-tail-mode.sh to pick economy vs full, then spawns agents/learn.md + agents/documentation.md as a parallel batch and waits for both before spawning agents/git.md (git must run AFTER doc + learn so late writes - lessons-tmp.md, doc edits - land in the commit). Teammate mode (under p1.md --teammate) skips detection and spawns documentation.md only - central p2.4 owns learn + git for the whole p2 session. Trace path is N/A (tail agents are non-trace per shared-guardrails).
---

# tail (p1.3 / p2.4)

Spec: `apex-core.md` p1.3 / p2.4 | `apex-core-overview.md` p1.3 / p2.4.

Single skill body, three invocation contexts. The caller passes `--phase p1` (main-mode p1.3), `--phase p2` (central Path 2 p2.4), or `--phase teammate` (teammate-mode p1.3); session token via `--session`.

## Invocation contexts

| Caller | Phase arg | Detection | Agents spawned | Notes |
|--------|-----------|-----------|----------------|-------|
| `p1.md` p1.3 (main mode) | `--phase p1` | yes | `economy` -> `git.md` (single spawn); `full` -> phase A parallel: `learn.md` + `documentation.md`; phase B (only after both return): `git.md` | apex-driven change set is captured by `{session}-baseline.json` head_sha. Two-phase sequencing is REQUIRED: learn appends to `lessons-tmp.md` and documentation writes spec docs - those landings must be committed by git, not stranded post-commit. |
| `p2.md` p2.4 (central) | `--phase p2` | yes | same as p1 by mode | `documentation.md` runs the integration pass: first-write on planner's `shared_files` list (orchestrator reads the list from the embedded plan body and substitutes it into the spawn prompt's `Shared files:` line; the agent receives the list, does not re-read the plan body) |
| `p1.md --teammate` p1.3 | `--phase teammate` | NO | `documentation.md` only | learn + git centralised at p2.4; teammate `documentation.md` is scoped to that teammate's allowed-files |

## Step 1: Resolve phase + detect mode

```
case "$PHASE" in
  p1|p2)    DETECT=1 ;;
  teammate) DETECT=0 ;;
  *)        echo "tail: invalid --phase '$PHASE' (expected p1|p2|teammate)" >&2 ; exit 2 ;;
esac

if (( DETECT )); then
  MODE=$(bash $HOME/.claude/skills/apex/scripts/detect-tail-mode.sh --session {session})
  rc=$?
  if (( rc != 0 )); then
    # baseline missing/invalid (rc=1) or invocation error (rc=2). Fail-silent
    # for the orchestrator: the tail step is best-effort - log and proceed.
    # learn / documentation / git are all idempotent enough that skipping
    # the whole step on a baseline read failure does not corrupt state.
    echo "tail: detect-tail-mode.sh failed (rc=$rc); skipping tail step" >&2
    exit 0
  fi
  case "$MODE" in
    economy) PHASE_A=(); PHASE_B=(git) ;;       # economy: skip phase A, only git
    full)    PHASE_A=(learn documentation); PHASE_B=(git) ;;
    *)       echo "tail: unexpected mode '$MODE' from detect-tail-mode.sh; defaulting to economy" >&2 ; PHASE_A=(); PHASE_B=(git) ;;
  esac
else
  # teammate mode: skip detection, docs only (no git phase B)
  PHASE_A=(documentation); PHASE_B=()
fi
```

## Step 2: Two-phase spawn (parallel A, then git)

Phase A and phase B are sequential; agents within a phase are parallel. The orchestrator MUST issue ONE message per phase (parallel batch), wait for all phase-A agents to return, then issue the phase-B message. This sequencing is REQUIRED so that late writes from phase A (`learn.md` appends to `lessons-tmp.md`; `documentation.md` writes spec docs) land BEFORE `git.md` reads `git diff` and stages - otherwise post-commit edits are stranded outside the commit.

All agents are Sonnet, foreground, no traces (tail agents are non-trace per `shared-guardrails.md`).

For each agent in `PHASE_A` (issued in parallel), then each agent in `PHASE_B` (after phase A returns), use the spawn-prompt template below. Substitute `{session}` and (where the template includes a `Phase:` line) `{phase}` (`p1` | `p2` | `teammate`). For the p2 documentation.md spawn, also substitute `{shared_files}` (comma-separated repo-relative paths from the planner's `shared_files` list, read from the embedded plan body).

### learn.md spawn prompt

```
You are agents/learn.md. Read it at $HOME/.claude/agents/learn.md and follow it.

Session:  {session}
Baseline: .claude-tmp/apex-active/{session}-baseline.json
```

### documentation.md spawn prompt

```
You are agents/documentation.md. Read it at $HOME/.claude/agents/documentation.md and follow it.

Session:      {session}
Phase:        {phase}        # p1 | p2 | teammate
Baseline:     .claude-tmp/apex-active/{session}-baseline.json
Shared files: {shared_files}   # p2 only; comma-separated repo-relative paths from planner's shared_files list. Empty/absent on p1 / teammate.
```

### git.md spawn prompt

```
You are agents/git.md. Read it at $HOME/.claude/agents/git.md and follow it.

Session:  {session}
Baseline: .claude-tmp/apex-active/{session}-baseline.json
```

## Fail-silent contract (whole step)

- `detect-tail-mode.sh` failure (rc != 0) -> log to stderr, skip the spawn batch, exit 0. The chain (p1.4 / p2.5) proceeds.
- Individual agent failure -> agent itself fail-silents (`git.md` per spec; `learn.md` and `documentation.md` per their own contracts) and returns success. The orchestrator does NOT block on tail.
- This is intentional: the tail step is best-effort (lessons, docs, git commit). Hard-failing here would block p1.4 / p1.5 / p1.6 (or p2.5 / p2.6 / p2.7) for cosmetic gains.

## Cleanup

Tail produces no session-keyed artifacts of its own. Lessons are appended to `.claude-tmp/lessons-tmp.md` (project-level, NOT session-scoped - cleanup is out of scope for /apex). Git commits are persistent. Doc writes are persistent. There is nothing for `cleanup-session.sh` to remove that is owned by tail.

## What this skill does NOT do

- Does NOT decide what to learn / what to document / what to commit - the agents do, with the baseline-pinned diff as input.
- Does NOT consult `screened-{session}.json` / findings - tail is post-implementation, not implementation.
- Does NOT extend scope - the agents inherit the orchestrator's scope-check pointer; cross-cutting writes are limited to the standard safety paths (docs/**, README* at any depth).
- Does NOT write traces - tail agents are non-trace per `shared-guardrails.md`.

See `agents/learn.md`, `agents/documentation.md`, `agents/git.md` for behavior contracts; `scripts/detect-tail-mode.sh` for the size-signal logic; `shared-guardrails.md` for safety paths and scope-check.
