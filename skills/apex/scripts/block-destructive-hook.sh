#!/usr/bin/env bash
# Guardrail hook: blocks destructive git commands, dangerous rm, and .env shell access.
# PreToolUse matcher: Bash
# Enforces CLAUDE.md Git Safety (Non-Negotiable) and Security sections.
# Exit 0 always -- blocks via JSON output per hook protocol.
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
deny() {
  local head='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'
  printf '%s,"permissionDecisionReason":"%s"}}\n' "$head" "$1"
}

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
  msg="GUARDRAIL: Extracting file contents from git history with redirection is equivalent to "
  msg+="git checkout -- and can overwrite uncommitted changes. Ask user via AskUserQuestion before proceeding."
  deny "$msg"
  exit 0
fi

# git stash pop (applies stash and drops it; can overwrite working-tree changes; loses safety net)
if [[ "$COMMAND" =~ git[[:space:]]+stash[[:space:]]+pop ]]; then
  msg="GUARDRAIL: git stash pop applies the stash and drops it -- can overwrite working-tree changes "
  msg+="and loses the stash safety net. All stash apply forms are blocked here (they can only target a "
  msg+="pre-existing USER stash and inject conflict markers). Commit your work instead, or ask the user "
  msg+="via AskUserQuestion before proceeding."
  deny "$msg"
  exit 0
fi

# git stash creation (push/save/bare/create/store) -- apex agents must NEVER stash.
# Per-apex-session worktrees eliminate cross-session sibling overlap, but inside
# ONE worktree the orchestrator + concurrent subagents (executor, discoverer,
# screener, reviewer, polish, learn, documentation) share a single working tree.
# A bare `git stash` (alias for `git stash push`) from any one of them silently
# captures EVERY co-resident agent's uncommitted edits into a single stash ref,
# which presents as catastrophic work loss for parallel siblings. Only read-only
# `list`/`show` stay allowed; `pop` has its own block above; `apply`/`branch`
# (the `git stash` subcommands, NOT `git branch`) are denied below because, with
# creation blocked, they can only ever target a pre-existing USER stash and
# 3-way-merge it into the working tree -- injecting conflict markers (real
# incident). Sub-command split mirrors CHECKOUT_BYPASS so a commit message or
# echo string containing "git stash" does not false-positive.
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
    # stash. Allow only read-only sub-commands ('list' / 'show').
    # 'pop' is handled by its own block above; listed here so a reordering of
    # blocks cannot accidentally route it through the deny path. 'drop' / 'clear'
    # are destructive stash-entry removal (drop = one entry, clear = all) and are
    # intentionally NOT allowlisted -> they fall through to deny.
    # 'apply' / 'branch' are ALSO denied (NOT recovery): because stash creation
    # is blocked above, an agent never owns a self-created stash, so a bare
    # `git stash apply` defaults to stash@{0} -- which can only be a pre-existing
    # USER stash -- and 3-way-merges it into the (clean) working tree, injecting
    # conflict markers. That is a real incident, not a hypothetical. 'git stash
    # branch' is the stash subcommand (NOT `git branch` / `git worktree add -b`,
    # which never reach this parser) and applies a stash the same way.
    # (apex-core.md ## Conventions, block-destructive hook / NEVER stash).
    if sub not in ('list', 'show', 'pop'):
        print('yes')
        sys.exit(0)
" 2>/dev/null || echo "")

if [[ "$STASH_CREATE" == "yes" ]]; then
  msg="GUARDRAIL: git stash is never allowed for apex agents. Creating a stash (push/save/bare/flags) "
  msg+="captures every co-resident subagent's uncommitted work into a single ref that looks like work "
  msg+="loss to parallel siblings. Applying one (apply/branch) can only target a pre-existing USER "
  msg+="stash here -- it defaults to stash@{0} and 3-way-merges it into your tree, injecting conflict "
  msg+="markers. Commit your work instead, or ask the user via AskUserQuestion."
  deny "$msg"
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
  msg="GUARDRAIL: git reset with --hard/--keep/--merge discards or rewrites uncommitted work. "
  msg+="Ask user via AskUserQuestion before proceeding."
  deny "$msg"
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
env_re='(cat|head|tail|less|more|source|\.|grep|rg|awk|sed)[[:space:]]+(.*\.env)([[:space:]]|$|[^.a-zA-Z])'
if [[ "$COMMAND" =~ $env_re ]]; then
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
  msg="GUARDRAIL: Dangerous rm command targets root, home, or project root. "
  msg+="Ask user via AskUserQuestion before proceeding."
  deny "$msg"
  exit 0
fi

echo "$ALLOW"
exit 0
