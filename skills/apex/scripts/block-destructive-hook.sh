#!/usr/bin/env bash
# Guardrail hook: blocks destructive git commands, dangerous rm, and .env shell access.
# PreToolUse matcher: Bash
# Enforces CLAUDE.md Git Safety (Non-Negotiable) and Security sections.
# Exit 0 always -- blocks via JSON output per hook protocol.
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() { echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$1\"}}"; }

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('command', ''))
" 2>/dev/null || echo "")

if [[ -z "$COMMAND" ]]; then
  echo "$ALLOW"
  exit 0
fi

# --- Destructive git commands (CLAUDE.md Git Safety Non-Negotiable) ---

# git checkout -- (discards working tree changes)
if [[ "$COMMAND" =~ git[[:space:]]+checkout[[:space:]]+-- ]]; then
  deny "GUARDRAIL: git checkout -- discards uncommitted changes. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# Workaround detection: git show/cat-file <ref>:<path> with output redirection
# Equivalent to git checkout -- when output is redirected to overwrite working tree files.
# Pattern: git show HEAD:file > /tmp/x && cp /tmp/x file (the actual bypass that occurred)
CHECKOUT_BYPASS=$(echo "$COMMAND" | python3 -c "
import re, sys
cmd = sys.stdin.read().strip()
# Split by command sequencing (&&, ;, ||) to isolate sub-commands.
# This prevents matching patterns inside commit message args or echo strings.
subcmds = re.split(r'\s*(?:&&|;|\|\|)\s*', cmd)
for s in subcmds:
    s = s.strip()
    # git show/cat-file at sub-command start, with ref:path, and output redirection
    if re.match(r'git\s+(show|cat-file)\b', s) and re.search(r'\S+:\S+', s) and re.search(r'[>|]', s):
        print('yes')
        sys.exit(0)
    # git archive at sub-command start with pipe to tar
    if re.match(r'git\s+archive\b', s) and re.search(r'\|\s*tar', s):
        print('yes')
        sys.exit(0)
" 2>/dev/null || echo "")

if [[ "$CHECKOUT_BYPASS" == "yes" ]]; then
  deny "GUARDRAIL: Extracting file contents from git history with redirection is equivalent to git checkout -- and can overwrite uncommitted changes. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git restore (without --staged discards working tree changes)
if [[ "$COMMAND" =~ git[[:space:]]+restore[[:space:]] ]] && ! [[ "$COMMAND" =~ --staged ]]; then
  deny "GUARDRAIL: git restore discards working tree changes. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git reset --hard (discards all uncommitted changes)
if [[ "$COMMAND" =~ git[[:space:]]+reset[[:space:]]+--hard ]]; then
  deny "GUARDRAIL: git reset --hard discards all uncommitted changes. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git clean -f (deletes untracked files)
if [[ "$COMMAND" =~ git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f ]]; then
  deny "GUARDRAIL: git clean -f deletes untracked files permanently. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git push --force / -f to main/master
if [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]] ]]; then
  if [[ "$COMMAND" =~ (--force|-f[[:space:]]|--force-with-lease) ]]; then
    if [[ "$COMMAND" =~ (main|master) ]]; then
      deny "GUARDRAIL: Force push to main/master is never allowed. This can destroy shared history."
      exit 0
    fi
  fi
fi

# --- .env file access via shell (CLAUDE.md Security Non-Negotiable) ---

# Catch: cat .env, head .env, tail .env, source .env, . .env, less .env, grep .env, rg .env, etc.
# But allow .env.example, .env.sample, .env.template
if [[ "$COMMAND" =~ (cat|head|tail|less|more|source|\.|grep|rg|awk|sed)[[:space:]]+(.*\.env)([[:space:]]|$|[^.a-zA-Z]) ]]; then
  if ! [[ "$COMMAND" =~ \.env\.(example|sample|template) ]]; then
    deny "GUARDRAIL: Cannot read .env files via shell -- they contain secrets. Use .env.example instead."
    exit 0
  fi
fi

# --- Dangerous rm operations ---

# rm with recursive flag targeting /, ~, ., or ..
DANGEROUS_RM=$(echo "$COMMAND" | python3 -c "
import re, sys
cmd = sys.stdin.read().strip()
m = re.search(r'rm\s+-[rRf]+\s+(.*)', cmd)
if not m:
    sys.exit(0)
target = m.group(1).split()[0] if m.group(1).strip() else ''
if re.match(r'^(/\*?|~/?(\*?)|\.\./?\*?|\./?\*?)$', target):
    print('yes')
" 2>/dev/null || echo "")

if [[ "$DANGEROUS_RM" == "yes" ]]; then
  deny "GUARDRAIL: Dangerous rm command targets root, home, or project root. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

echo "$ALLOW"
exit 0
