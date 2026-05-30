#!/usr/bin/env bash
# PreToolUse hook: file-health gate.
# Spec: user-global CLAUDE.md "File health (enforced gate)".
#
# Blocks Edit / Write / MultiEdit when:
#   - the existing target file is > 400 lines, AND
#   - the proposed change adds > 10 lines (net delta).
#
# Trivial edits (<= 10 lines net) always pass, even on > 500-line files.
# New files (target does not exist on disk) always pass.
# NotebookEdit is excluded - .ipynb is JSON-encoded; line-count gating on the
# wire format is not meaningful (the rule is about source-text files).
#
# Exception: continuous-prose documents (.md / .markdown - legal prose, central
# spec docs) are exempt directly by this hook. The split rule targets source
# text, not prose (CLAUDE.md File health exception; apex-core.md step 8 "*.md
# heuristic"), so the gate is waived for them here rather than enforced-then-
# bypassed at the prompt layer. Non-prose files past the cap must be split first.
#
# Exit 0 always; block via JSON output per hook protocol (matches the
# protect-env-hook.sh / block-destructive-hook.sh idiom in this repo).

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

INPUT=$(cat)

DECISION=$(printf '%s' "$INPUT" | python3 -c '
import json, sys

ALLOW = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"}}"

def deny(reason):
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }})

try:
    event = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print(ALLOW); sys.exit(0)

tool = event.get("tool_name", "")
inputs = event.get("tool_input", {}) or {}
target = inputs.get("file_path", "")

if tool not in ("Edit", "Write", "MultiEdit") or not target:
    print(ALLOW); sys.exit(0)

try:
    with open(target, "r", encoding="utf-8") as f:
        existing = sum(1 for _ in f)
except (FileNotFoundError, IsADirectoryError, OSError):
    print(ALLOW); sys.exit(0)

if existing == 0:
    print(ALLOW); sys.exit(0)

# Continuous-prose exemption: .md / .markdown docs are single-concern continuous
# documents (CLAUDE.md File health exception; apex-core.md step 8 "*.md
# heuristic"). The split rule does not apply to prose, so waive the gate.
import os
if os.path.splitext(target)[1].lower() in (".md", ".markdown"):
    print(ALLOW); sys.exit(0)

if tool == "Write":
    content = inputs.get("content", "")
    new_lines = content.count("\n") + (1 if content and not content.endswith("\n") else 0)
    added = max(0, new_lines - existing)
elif tool == "Edit":
    added = inputs.get("new_string", "").count("\n") - inputs.get("old_string", "").count("\n")
else:  # MultiEdit
    added = sum(
        e.get("new_string", "").count("\n") - e.get("old_string", "").count("\n")
        for e in inputs.get("edits", [])
    )

if added <= 10:
    print(ALLOW); sys.exit(0)

if existing > 400:
    threshold = 500 if existing > 500 else 400
    sibling_hint = ""
    try:
        import os, glob
        target_dir = os.path.dirname(target) or "."
        target_base = os.path.basename(target)
        target_stem, target_ext = os.path.splitext(target_base)
        siblings = []
        for sib_path in sorted(glob.glob(os.path.join(target_dir, f"*{target_ext}"))):
            sib_base = os.path.basename(sib_path)
            if sib_base == target_base:
                continue
            sib_stem = os.path.splitext(sib_base)[0]
            if "_" in target_stem and target_stem.split("_", 1)[0] == sib_stem.split("_", 1)[0]:
                siblings.append(sib_base)
        if siblings:
            extra = " + others" if len(siblings) > 1 else ""
            sibling_hint = (f" Sibling helpers in same directory suggest split target: "
                            f"{siblings[0]}{extra}.")
    except Exception:
        pass
    msg = (f"file-health gate: {target} is {existing} lines (>{threshold}). "
           f"Split first - extract a separable concern before adding {added}+ lines.{sibling_hint} "
           f"See global CLAUDE.md File health.")
    print(deny(msg)); sys.exit(0)

print(ALLOW)
' 2>/dev/null) || DECISION="$ALLOW"

echo "$DECISION"
exit 0
