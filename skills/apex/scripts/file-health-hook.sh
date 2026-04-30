#!/usr/bin/env bash
# PreToolUse hook: oversize file gate.
# See user-global CLAUDE.md "File health" rule.
#
# Behavior:
#   - Reads PreToolUse event JSON from stdin
#   - Extracts target file path from Edit / Write / MultiEdit / NotebookEdit input
#   - Runs wc -l on existing file (skip if file does not exist - new file)
#   - If file > 400 lines AND tool would add > 10 lines: block with message instructing split first
#   - If file > 500 lines AND tool would add > 10 lines: block (split regardless of change size)
#
# Exception: single-concern continuous documents (terms / privacy legal prose) - convention-enforced
# at prompt layer; this hook does not have semantic awareness of file purpose.
#
# Exit codes (Claude Code hook contract):
#   0   = pass (allow tool call)
#   2   = block (deny + return reason to Claude)
#   1   = error (treat as pass to avoid breaking flow)
#
# TODO: implement.

set -euo pipefail
exit 0
