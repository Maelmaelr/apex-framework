#!/usr/bin/env bash
# PreToolUse hook: file-health gate.
# Spec: user-global CLAUDE.md "File health".
#
# Docs (.md / .markdown):
#   - apex framework skills/** + agents/** docs gate on a CONTENT BUDGET
#     (projected word count > DOC_WORD_CAP) rather than net line delta - physical
#     newline count is gamed by one-paragraph-per-line markdown.
#   - repo-root CLAUDE.md stays exempt (single-concern continuous document).
#   - all other .md (non-apex trees) stay exempt, unchanged.
#
# Code (non-.md):
#   - line-count split gate (global): existing file > 400 lines AND change adds
#     > 10 net lines -> deny (split a separable concern first).
#   - max-line-length gate (apex framework skills/** + agents/** scripts): an edit
#     that introduces a line longer than MAX_LINE_LEN chars -> deny (wrap/refactor).
#     Data formats (.json/.yaml/.yml) are EXEMPT - their long string values
#     (schema descriptions, prompt strings) cannot wrap; they keep the split gate.
#
# Trivial edits (<= 10 net lines) pass the code line gate even on > 500-line
# files. Shrinking/neutral doc edits and new files (target absent on disk) always
# pass. NotebookEdit is excluded - .ipynb is JSON-encoded; line gating on the wire
# format is not meaningful (the rule is about source-text files).
#
# Exit 0 always; block via JSON output per hook protocol (matches the
# protect-env-hook.sh / block-destructive-hook.sh idiom in this repo).

set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

INPUT=$(cat)

DECISION=$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys

ALLOW = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"}}"

APEX_ROOT = os.path.join(os.path.expanduser("~"), ".claude")
SKILLS_ROOT = os.path.join(APEX_ROOT, "skills") + os.sep
AGENTS_ROOT = os.path.join(APEX_ROOT, "agents") + os.sep
CENTRAL_SPECS = {os.path.join(APEX_ROOT, "CLAUDE.md")}
# Per-role skills/agents .md word caps live in content-budget.json. DOC_WORD_CAP is
# the fail-safe fallback default used only when that file is missing/unparseable.
DOC_WORD_CAP = 2500
LINE_SPLIT_CAP = 400
MAX_LINE_LEN = 120
# Data formats carry unwrappable long string values (JSON schema descriptions,
# prompt strings, regex) - exempt from the max-line-length gate, like .md.
DATA_EXTS = (".json", ".yaml", ".yml")
CONTENT_BUDGET = os.path.join(APEX_ROOT, "skills", "apex", "scripts", "content-budget.json")


def load_tiers():
    """(default_cap, tiers) from content-budget.json; fail-safe to flat default."""
    try:
        with open(CONTENT_BUDGET, encoding="utf-8") as f:
            data = json.load(f)
        return int(data.get("default", DOC_WORD_CAP)), dict(data.get("tiers", {}))
    except (OSError, ValueError):
        return DOC_WORD_CAP, {}


def cap_for(target, default_cap, tiers):
    """Resolve a skills/agents .md target word cap by repo-relative path."""
    try:
        rel = os.path.relpath(os.path.abspath(target), APEX_ROOT)
    except ValueError:
        return default_cap
    return tiers.get(rel, default_cap)


def deny(reason):
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }})


def word_count(s):
    return len(s.split())


def projected_words(tool, inputs, existing):
    base = word_count(existing)
    if tool == "Write":
        return word_count(inputs.get("content", ""))
    if tool == "Edit":
        return base + word_count(inputs.get("new_string", "")) - word_count(inputs.get("old_string", ""))
    return base + sum(word_count(e.get("new_string", "")) - word_count(e.get("old_string", ""))
                      for e in inputs.get("edits", []))


def doc_decision(tool, target, inputs):
    # apex skills/agents docs: gate on projected word budget, allow shrink/neutral.
    try:
        with open(target, encoding="utf-8", errors="ignore") as f:
            existing = f.read()
    except OSError:
        return ALLOW
    base = word_count(existing)
    proj = projected_words(tool, inputs, existing)
    if proj <= base:
        return ALLOW
    default_cap, tiers = load_tiers()
    cap = cap_for(target, default_cap, tiers)
    if proj > cap:
        return deny(f"file-health gate: {target} would be ~{proj} words "
                    f"(> {cap}-word content budget). Split first - extract a "
                    f"separable concern before growing it. See global CLAUDE.md File health.")
    return ALLOW


def new_text_lines(tool, inputs):
    if tool == "Write":
        return inputs.get("content", "").split("\n")
    if tool == "Edit":
        return inputs.get("new_string", "").split("\n")
    out = []
    for e in inputs.get("edits", []):
        out.extend(e.get("new_string", "").split("\n"))
    return out


def added_lines(tool, inputs, existing_lines):
    if tool == "Write":
        content = inputs.get("content", "")
        new_lines = content.count("\n") + (1 if content and not content.endswith("\n") else 0)
        return max(0, new_lines - existing_lines)
    if tool == "Edit":
        return inputs.get("new_string", "").count("\n") - inputs.get("old_string", "").count("\n")
    return sum(e.get("new_string", "").count("\n") - e.get("old_string", "").count("\n")
               for e in inputs.get("edits", []))


def sibling_hint(target):
    try:
        import glob
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
            return (f" Sibling helpers in same directory suggest split target: "
                    f"{siblings[0]}{extra}.")
    except Exception:
        pass
    return ""


def line_split_decision(target, tool, inputs):
    try:
        with open(target, "r", encoding="utf-8") as f:
            existing = sum(1 for _ in f)
    except (FileNotFoundError, IsADirectoryError, OSError):
        return ALLOW
    if existing == 0:
        return ALLOW
    added = added_lines(tool, inputs, existing)
    if added <= 10:
        return ALLOW
    if existing > LINE_SPLIT_CAP:
        threshold = 500 if existing > 500 else 400
        msg = (f"file-health gate: {target} is {existing} lines (>{threshold}). "
               f"Split first - extract a separable concern before adding {added}+ "
               f"lines.{sibling_hint(target)} See global CLAUDE.md File health.")
        return deny(msg)
    return ALLOW


def code_decision(tool, target, inputs):
    abs_t = os.path.abspath(target)
    ext = os.path.splitext(target)[1].lower()
    # max-line-length is a code-readability rule; data formats are exempt (their
    # long string values cannot wrap) but still gated on file-size by line_split.
    if ext not in DATA_EXTS and (abs_t.startswith(SKILLS_ROOT) or abs_t.startswith(AGENTS_ROOT)):
        longest = max((len(ln) for ln in new_text_lines(tool, inputs)), default=0)
        if longest > MAX_LINE_LEN:
            return deny(f"file-health gate: {target} edit introduces a {longest}-char "
                        f"line (> {MAX_LINE_LEN}). Wrap or refactor. See global CLAUDE.md File health.")
    return line_split_decision(target, tool, inputs)


def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return ALLOW
    tool = event.get("tool_name", "")
    inputs = event.get("tool_input", {}) or {}
    target = inputs.get("file_path", "")
    if tool not in ("Edit", "Write", "MultiEdit") or not target:
        return ALLOW
    ext = os.path.splitext(target)[1].lower()
    if ext in (".md", ".markdown"):
        abs_t = os.path.abspath(target)
        if abs_t in CENTRAL_SPECS:
            return ALLOW
        if abs_t.startswith(SKILLS_ROOT) or abs_t.startswith(AGENTS_ROOT):
            return doc_decision(tool, target, inputs)
        return ALLOW
    return code_decision(tool, target, inputs)


print(main())
' 2>/dev/null) || DECISION="$ALLOW"

echo "$DECISION"
exit 0
