#!/usr/bin/env bash
# Guardrail hook: blocks destructive git commands, dangerous rm, and .env shell access.
# PreToolUse matcher: Bash
# Enforces CLAUDE.md Git Safety (Non-Negotiable) and Security sections.
# Exit 0 always -- blocks via JSON output per hook protocol.
#
# Scope honesty: this is a TRIPWIRE against the common accidental forms, not a
# boundary -- string-level matching cannot see through script indirection
# (bash file.sh), env-prefixed invocations, or aliases. The worktree fence and
# agent contracts carry the rest.
#
# All parsing lives in ONE python program fed through a QUOTED heredoc
# (<<'PY') with the command passed via env var. Never inline the python in a
# double-quoted bash string: backticks or $() inside it (even in python
# comments) undergo shell command substitution at hook runtime -- a previous
# version executed git commands as a side effect on every Bash call that way.
# Regression guard: the test suite asserts this file contains no backtick.
#
# Checks (per &&/;/|| sub-command; git prefix options -c/-C/--git-dir/
# --work-tree are consumed before the subcommand match):
#   - git checkout with a standalone pathspec separator (--)
#   - git restore without --staged, or with --worktree/-W
#   - git stash: everything except read-only list/show
#   - git reset --hard/--keep/--merge (flag anywhere in argv)
#   - git clean with -f/--force
#   - git push with any force flag, or a +refspec (force-push syntax)
#   - git show/cat-file <ref>:<path> redirected, git archive|tar (checkout
#     workarounds)
#   - git worktree remove / git branch -D when the cwd is inside an apex
#     worktree (self-teardown belongs to /apex-merge or the user, from MAIN)
#   - recursive rm on root/home/dot targets, on .apex-worktrees, under the
#     home tree (framework scratch excepted), or on absolute paths outside
#     tmp scratch
#   - shell readers/copiers of .env* (example/sample/template excepted)
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

INPUT=$(cat)

DECISION=$(GUARD_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, re, sys

def emit(decision, reason=None):
    h = {"hookEventName": "PreToolUse", "permissionDecision": decision}
    if reason is not None:
        h["permissionDecisionReason"] = reason
    print(json.dumps({"hookSpecificOutput": h}))
    sys.exit(0)

def deny(reason):
    emit("deny", "GUARDRAIL: " + reason)

try:
    data = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
    cmd = ((data.get("tool_input") or {}).get("command", "") or "").strip()
except Exception:
    cmd = ""
if not cmd:
    emit("allow")

ASK = " Ask user via AskUserQuestion before proceeding."
CWD = os.getcwd() + "/"
IN_WORKTREE = "/.apex-worktrees/" in CWD

# git invocations tolerate prefix options before the subcommand
# (git -c X=Y reset --hard / git -C path checkout -- were real bypasses).
GIT = r"git(?:\s+-[cC]\s+\S+|\s+--(?:git-dir|work-tree)(?:=\S+|\s+\S+))*\s+"

def gitsub(seg, sub):
    return re.match(GIT + sub + r"\b", seg)

SAFE_ENV = ("example", "sample", "template")
ENV_READERS = (
    r"(?:cat|head|tail|less|more|source|\.|grep|rg|awk|sed|cut|tr|sort|uniq"
    r"|strings|xxd|od|hexdump|base64|dd|cp|mv|python3?|node|deno|bun|ruby|perl|php)"
)

def env_hit(seg):
    # Reader/copier command followed by a path whose component starts with .env
    # (production.env is not .env; .env.example/.sample/.template are safe).
    if not re.match(ENV_READERS + r"\s", seg):
        return False
    for tok in re.findall(r"(?:^|[\s/'\"=])(\.env[\w.-]*)", seg):
        if tok in tuple(".env." + s for s in SAFE_ENV):
            continue
        return True
    return False

RM_SCRATCH_ABS = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
RM_SCRATCH_HOME = ("~/.claude/tmp/", "~/.claude/.claude-tmp/")

def check_rm(seg):
    m = re.match(r"rm\s+(.*)$", seg)
    if not m:
        return
    toks = m.group(1).split()
    flags = [t for t in toks if t.startswith("-")]
    targets = [t.strip("'\"") for t in toks if not t.startswith("-")]
    recursive = any(re.match(r"^-[a-zA-Z]*[rR]", f) or f == "--recursive" for f in flags)
    if not recursive:
        return
    for t in targets:
        if re.match(r"^(/\*?|~/?\*?|\.{1,2}/?\*?|\*)$", t):
            deny("Dangerous rm command targets root, home, or project root." + ASK)
        if ".apex-worktrees" in t:
            deny("Recursive rm on .apex-worktrees tears down session worktrees; removal belongs to"
                 " /apex-merge or the user, from the MAIN tree." + ASK)
        if t.startswith("~") and not t.startswith(RM_SCRATCH_HOME):
            deny("Recursive rm under the home tree is destructive outside the repo." + ASK)
        if t.startswith("/") and not t.startswith(RM_SCRATCH_ABS):
            deny("Recursive rm on an absolute path outside tmp scratch. Use a relative path from the"
                 " repo you are working in, or ask the user." + ASK)

for s in [x.strip() for x in re.split(r"\s*(?:&&|\|\||;)\s*", cmd) if x.strip()]:
    # --- destructive git commands (CLAUDE.md Git Safety Non-Negotiable) ---
    if gitsub(s, "checkout") and re.search(r"(?:^|\s)--(?:\s|$)", s):
        deny("git checkout with a pathspec separator (--) discards uncommitted changes." + ASK)
    if gitsub(s, "restore") and (re.search(r"(?:^|\s)(--worktree|-W)\b", s)
                                 or not re.search(r"(?:^|\s)(--staged|-S)\b", s)):
        deny("git restore discards working tree changes." + ASK)
    m = re.match(GIT + r"stash\b\s*(\S*)", s)
    if m and m.group(1) not in ("list", "show"):
        deny("git stash is never allowed for apex agents. Creating a stash captures every"
             " co-resident subagent's uncommitted work into one ref; pop/apply/branch can only"
             " target a pre-existing USER stash and 3-way-merge conflict markers into the tree."
             " Commit your work instead." + ASK)
    m = re.match(GIT + r"reset\b(.*)$", s)
    if m and re.search(r"(?:^|\s)(--hard|--keep|--merge)(?:\s|=|$)", m.group(1)):
        deny("git reset with --hard/--keep/--merge discards or rewrites uncommitted work." + ASK)
    if gitsub(s, "clean") and re.search(r"(?:^|\s)(-[a-zA-Z]*f[a-zA-Z]*|--force)\b", s):
        deny("git clean -f deletes untracked files permanently." + ASK)
    if gitsub(s, "push"):
        if re.search(r"(?:^|\s)(--force(-with-lease)?(=\S+)?|-f)(?:\s|$)", s):
            deny("Force push is a destructive operation (CLAUDE.md Destructive Operations)." + ASK)
        if re.search(r"\s\+\S+", s):
            deny("A refspec with a leading + is force-push syntax." + ASK)
    # --- checkout-equivalent extraction workarounds ---
    if gitsub(s, "(show|cat-file)") and re.search(r"\S+:\S+", s) and re.search(r">(?!&)|\|", s):
        deny("Extracting file contents from git history with redirection is equivalent to"
             " git checkout -- and can overwrite uncommitted changes." + ASK)
    if gitsub(s, "archive") and re.search(r"\|\s*tar", s):
        deny("git archive piped to tar extracts historical file contents over the working tree,"
             " equivalent to git checkout --." + ASK)
    # --- self-teardown guard (apex worktree cwd only) ---
    if IN_WORKTREE and (re.match(GIT + r"worktree\s+remove\b", s)
                        or re.match(GIT + r"branch\s+(-D|-d|--delete)\b", s)):
        deny("Never remove a worktree or delete a branch from inside an apex session; removal"
             " belongs to /apex-merge or the user, run from the MAIN tree.")
    # --- dangerous rm ---
    check_rm(s)
    # --- .env access via shell (CLAUDE.md Security Non-Negotiable) ---
    if env_hit(s):
        deny("Cannot read or copy .env files via shell -- they contain secrets."
             " Use .env.example instead.")

emit("allow")
PY
)

if [[ -n "$DECISION" ]]; then
  printf '%s\n' "$DECISION"
else
  echo "$ALLOW"
fi
exit 0
