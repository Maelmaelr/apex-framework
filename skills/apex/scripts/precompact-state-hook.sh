#!/usr/bin/env bash
# PreCompact + PostCompact + StopFailure hook: state preservation across compaction.
# See user-global CLAUDE.md "Compaction Preservation" rule.
#
# Behavior:
#   - PreCompact: echo a structured "preserve-state" block listing apex-critical fields:
#       task description, session start time, current APEX path (1/2), active step number,
#       file ownership claims, scout findings file path, tail mode, user decisions
#     so the compactor cannot drop them.
#   - PostCompact: re-inject the preserved block back into the conversation context.
#   - StopFailure: same preservation block (defensive snapshot for retry context).
#
# The hook is dispatched by event name (Claude Code passes hook event in stdin JSON);
# branches internally rather than registering 3 separate hook scripts.
#
# Exit codes: 0 = pass | 1 = error (treat as pass to avoid breaking flow)
#
# TODO: implement.

set -euo pipefail
exit 0
