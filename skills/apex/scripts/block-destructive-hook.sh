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
    # git show/cat-file at sub-command start, with ref:path, and output redirection.
    # The negative lookahead (?!&) on > excludes fd-dup tokens (n>&m, >&n like 2>&1, 1>&2)
    # while still matching file-write redirections (>, >>, &>, n>file). \| matches pipes.
    if re.match(r'git\s+(show|cat-file)\b', s) and re.search(r'\S+:\S+', s) and re.search(r'>(?!&)|\|', s):
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

# git stash pop (applies stash and drops it; can overwrite working-tree changes; loses safety net)
if [[ "$COMMAND" =~ git[[:space:]]+stash[[:space:]]+pop ]]; then
  deny "GUARDRAIL: git stash pop applies the stash and drops it -- can overwrite working-tree changes and loses the stash safety net. Use 'git stash apply' (keeps stash) instead, or ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git stash creation (push/save/bare/create/store) -- apex agents must NEVER stash.
# A bare `git stash` (alias for `git stash push`) in a shared worktree silently
# captures EVERY agent's uncommitted work into a stash ref; under parallel
# executors this looks like catastrophic work loss for siblings. Read-only
# (list/show) and non-destructive recovery (apply/branch) stay allowed; `pop`
# has its own block above. Sub-command split mirrors CHECKOUT_BYPASS so a
# commit message or echo string containing "git stash" does not false-positive.
STASH_CREATE=$(echo "$COMMAND" | python3 -c "
import re, sys
cmd = sys.stdin.read().strip()
subcmds = re.split(r'\s*(?:&&|;|\|\|)\s*', cmd)
for s in subcmds:
    s = s.strip()
    m = re.match(r'git\s+stash\b\s*(\S*)', s)
    if not m:
        continue
    sub = m.group(1)
    # Deny-by-default: bare 'git stash' (== push), push/save/create/store, and
    # every flag form (-p / -u / -k / -m / --include-untracked ...) all CREATE a
    # stash. Allow only read-only + non-destructive recovery sub-commands.
    # 'pop' is handled by its own block above; listed here so a reordering of
    # blocks cannot accidentally route it through the deny path.
    if sub not in ('list', 'show', 'apply', 'branch', 'pop', 'drop', 'clear'):
        print('yes')
        sys.exit(0)
" 2>/dev/null || echo "")

if [[ "$STASH_CREATE" == "yes" ]]; then
  deny "GUARDRAIL: git stash (push/save/bare) is never allowed for apex agents -- in a shared worktree it silently captures every agent's uncommitted work into a stash ref and looks like work loss to parallel siblings. Commit your work instead, or ask the user via AskUserQuestion."
  exit 0
fi

# git restore (without --staged discards working tree changes)
if [[ "$COMMAND" =~ git[[:space:]]+restore[[:space:]] ]] && ! [[ "$COMMAND" =~ --staged ]]; then
  deny "GUARDRAIL: git restore discards working tree changes. Ask user via AskUserQuestion before proceeding."
  exit 0
fi

# git reset with --hard/--keep/--merge (all discard or rewrite working-tree state).
# The simple `git\s+reset\s+--hard` regex was bypassed by:
#   - flag-after-ref: `git reset 725fdcfd --hard`
#   - per-invocation config:  `git -c X=Y reset --hard`
#   - per-command cwd:        `git -C path reset --hard`
# Sub-command split + python parser mirrors CHECKOUT_BYPASS / STASH_CREATE: each
# segment is normalized, `git` prefix flags consumed, then --hard/--keep/--merge
# is matched anywhere in the remaining argv.
RESET_DESTRUCTIVE=$(echo "$COMMAND" | python3 -c "
import re, sys
cmd = sys.stdin.read().strip()
subcmds = re.split(r'\s*(?:&&|;|\|\|)\s*', cmd)
for s in subcmds:
    s = s.strip()
    # git, then any number of -c X=Y or -C path prefix options, then reset.
    m = re.match(r'git\b(?:\s+-[cC]\s+\S+)*\s+reset\b(.*)$', s)
    if not m:
        continue
    args = m.group(1)
    if re.search(r'(?:^|\s)(--hard|--keep|--merge)(?:\s|=|$)', args):
        print('yes')
        sys.exit(0)
" 2>/dev/null || echo "")

if [[ "$RESET_DESTRUCTIVE" == "yes" ]]; then
  deny "GUARDRAIL: git reset with --hard/--keep/--merge discards or rewrites uncommitted work. Ask user via AskUserQuestion before proceeding."
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
