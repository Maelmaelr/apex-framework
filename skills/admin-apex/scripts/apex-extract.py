#!/usr/bin/env python3
"""Extract compact summary from Claude Code JSONL transcript.

Usage: python3 apex-extract.py <transcript.jsonl> [> output.md]

Output format per line:
  [line] TEXT: <first 500 chars of assistant text>
  [line] CALL <tool_name>: <key input detail>
  [line] ERROR: <error text>
Footer: total lines, error count, tool usage counts by frequency.
"""
# Exit 0 = success, Exit 1 = usage error.

import json
import os
import sys
from collections import Counter

SKIP_TYPES = {"file-history-snapshot", "summary"}


def basename(path):
    return os.path.basename(path) if path else ""


def extract_tool_detail(name, tool_input):
    """Extract key detail from tool input based on tool name."""
    if not isinstance(tool_input, dict):
        return str(tool_input)[:200]

    if name == "Agent":
        desc = tool_input.get("description", "")
        parts = [desc]
        st = tool_input.get("subagent_type")
        if st:
            parts.append(f"[{st}]")
        model = tool_input.get("model")
        if model:
            parts.append(f"[{model}]")
        return " ".join(parts)

    if name == "Read":
        fp = basename(tool_input.get("file_path", ""))
        parts = [fp]
        offset = tool_input.get("offset")
        limit = tool_input.get("limit")
        if offset is not None or limit is not None:
            parts.append(f"[{offset}:{limit}]")
        return " ".join(parts)

    if name == "Grep":
        pattern = tool_input.get("pattern", "")
        path = tool_input.get("path")
        detail = pattern[:100]
        if path:
            detail += f" in {basename(path)}"
        return detail

    if name == "Glob":
        pattern = tool_input.get("pattern", "")
        path = tool_input.get("path")
        detail = pattern[:100]
        if path:
            detail += f" in {basename(path)}"
        return detail

    if name == "TaskCreate":
        return tool_input.get("subject", "")[:200]

    if name == "TaskUpdate":
        tid = tool_input.get("taskId", "")
        status = tool_input.get("status", "")
        return f"#{tid} -> {status}" if status else f"#{tid}"

    if name == "Edit" or name == "Write":
        return basename(tool_input.get("file_path", ""))

    if name == "Bash":
        cmd = tool_input.get("command", "")
        return cmd[:200]

    if name == "AskUserQuestion":
        return tool_input.get("questions", [{}])[0].get("question", "")[:200]

    if name == "Skill":
        skill = tool_input.get("skill", "")
        args = tool_input.get("args")
        return f"{skill} {args}" if args else skill

    if name == "EnterPlanMode":
        return "enter"

    if name == "ExitPlanMode":
        return "exit"

    if name == "SendMessage":
        to = tool_input.get("to", "")
        msg = str(tool_input.get("message", ""))[:100]
        return f"to={to} {msg}"

    if name == "TeamCreate" or name == "TeamDelete":
        return tool_input.get("name", "")

    if name == "ToolSearch":
        return tool_input.get("query", "")

    # Fallback: description or first 200 chars of stringified input
    desc = tool_input.get("description") or tool_input.get("subject")
    if desc:
        return str(desc)[:200]
    return str(tool_input)[:200]


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 apex-extract.py <transcript.jsonl>", file=sys.stderr)
        sys.exit(1)

    transcript_path = sys.argv[1]
    tool_counts = Counter()
    error_count = 0
    line_num = 0

    with open(transcript_path, "r") as f:
        for raw_line in f:
            line_num += 1
            raw_line = raw_line.strip()
            if not raw_line:
                continue

            try:
                entry = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            entry_type = entry.get("type", "")
            if entry_type in SKIP_TYPES:
                continue

            message = entry.get("message", {})
            if not isinstance(message, dict):
                continue

            role = message.get("role", "")
            content = message.get("content", "")

            if role == "assistant":
                if isinstance(content, str) and content.strip():
                    print(f"[{line_num}] TEXT: {content[:500]}")
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        btype = block.get("type", "")

                        if btype == "text":
                            text = block.get("text", "").strip()
                            if text:
                                print(f"[{line_num}] TEXT: {text[:500]}")

                        elif btype == "tool_use":
                            tool_name = block.get("name", "unknown")
                            tool_input = block.get("input", {})
                            detail = extract_tool_detail(tool_name, tool_input)
                            tool_counts[tool_name] += 1
                            print(f"[{line_num}] CALL {tool_name}: {detail}")

            elif role == "tool":
                # Check for errors in tool results
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("is_error"):
                            error_text = block.get("text", "")[:300]
                            error_count += 1
                            print(f"[{line_num}] ERROR: {error_text}")
                elif isinstance(content, dict) and content.get("is_error"):
                    error_text = content.get("text", "")[:300]
                    error_count += 1
                    print(f"[{line_num}] ERROR: {error_text}")

            elif role == "user":
                if isinstance(content, str) and content.strip():
                    print(f"[{line_num}] USER: {content[:300]}")
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            text = block.get("text", "").strip()
                            if text:
                                print(f"[{line_num}] USER: {text[:300]}")

    # Stats footer
    print(f"\n--- Stats ---")
    print(f"Total lines: {line_num}")
    print(f"Errors: {error_count}")
    if tool_counts:
        print("Tool usage (by frequency):")
        for tool, count in tool_counts.most_common():
            print(f"  {tool}: {count}")


if __name__ == "__main__":
    main()
