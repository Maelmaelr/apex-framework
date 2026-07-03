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
#   - worktree-fence tripwire (armed apex sessions only; shares the fence
#     hook's arming model - cwd inside .apex-worktrees/ OR a session record
#     at $APEX_FENCE_DIR/<cc_session_id> written by mint-worktree.sh):
#     redirect / tee / sed -i / cp / mv write targets resolving outside the
#     worktree (scratch + MAIN .claude-tmp allow-listed), and benign-form git
#     tree mutations (add/commit/checkout/...) whose effective tree - the -C /
#     --work-tree path, else the cwd - sits outside the worktree. Catches the
#     Bash writes the edit-tool fence cannot see; still a tripwire, not a
#     boundary.
set -euo pipefail

ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

INPUT=$(cat)

DECISION=$(GUARD_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys

def emit(decision, reason=None):
    h = {"hookEventName": "PreToolUse", "permissionDecision": decision}
    if reason is not None:
        h["permissionDecisionReason"] = reason
    print(json.dumps({"hookSpecificOutput": h}))
    sys.exit(0)

def deny(reason):
    emit("deny", "GUARDRAIL: " + reason)

data = {}
try:
    data = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
    cmd = ((data.get("tool_input") or {}).get("command", "") or "").strip()
except Exception:
    data = {}
    cmd = ""
if not cmd or not isinstance(data, dict):
    emit("allow")

ASK = " Ask user via AskUserQuestion before proceeding."
CWD = os.getcwd() + "/"
IN_WORKTREE = "/.apex-worktrees/" in CWD

# --- worktree-fence arming (shared model with worktree-fence-hook.sh) ---
MARK = "/.apex-worktrees/"
EVENT_CWD = str(data.get("cwd") or "")

def wt_root_of(path):
    # Worktree root when path sits inside .apex-worktrees/<token>/, else None.
    p = path + "/"
    if MARK not in p:
        return None
    head, tail = p.split(MARK, 1)
    tok = tail.split("/", 1)[0]
    return head + MARK + tok if tok else None

if wt_root_of(os.getcwd()):
    BASE_CWD = os.getcwd()
elif wt_root_of(EVENT_CWD):
    BASE_CWD = EVENT_CWD
else:
    BASE_CWD = EVENT_CWD or os.getcwd()
WT_ROOT = wt_root_of(os.getcwd()) or wt_root_of(EVENT_CWD)
def claude_pid():
    # Closest claude ancestor pid (mirrors find-claude-pid.sh). The record's
    # pid key survives /clear session-id rotation.
    pid = os.getppid()
    for _ in range(8):
        try:
            comm = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)],
                                  capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            return None
        if os.path.basename(comm) == "claude":
            return pid
        try:
            pp = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                                capture_output=True, text=True, timeout=2).stdout.strip()
            pid = int(pp)
        except Exception:
            return None
        if pid in (0, 1):
            return None
    return None

RECORD_ARMED = False
REC_PATH = ""
if WT_ROOT is None:
    fdir = os.environ.get("APEX_FENCE_DIR") or os.path.expanduser("~/.claude/tmp/apex-fence")
    try:
        have_recs = bool(os.listdir(fdir))
    except Exception:
        have_recs = False
    rec = ""
    if have_recs:
        # Two keys, first hit wins: event session_id, then pid-<claude-pid>.
        # The pid walk (ps calls) only runs when records exist and sid missed.
        sid = str(data.get("session_id") or os.environ.get("CC_SESSION_ID") or "").strip()
        if sid and os.path.isfile(os.path.join(fdir, sid)):
            rec = os.path.join(fdir, sid)
        else:
            cp = claude_pid()
            if cp and os.path.isfile(os.path.join(fdir, "pid-" + str(cp))):
                rec = os.path.join(fdir, "pid-" + str(cp))
    if rec:
        try:
            with open(rec, encoding="utf-8") as fh:
                wt = fh.readline().strip()
        except Exception:
            wt = ""
        if wt and os.path.isdir(wt):
            WT_ROOT, RECORD_ARMED, REC_PATH = wt, True, rec

SCRATCH = (os.path.expanduser("~/.claude/tmp") + "/", "/tmp/", "/private/tmp/",
           "/var/folders/", "/private/var/folders/")

def fence_hint():
    hint = (" This apex session's writes must stay under its worktree ("
            + WT_ROOT + ") or framework scratch (/tmp, ~/.claude/tmp).")
    if RECORD_ARMED:
        hint += (" Unanchored context: cd " + WT_ROOT + " first. If main-tree work is"
                 " intentional (apex finished), disarm: rm " + REC_PATH)
    return hint

def escapes_fence(tok):
    # Resolved path when tok is a path-like write target OUTSIDE the armed
    # worktree and its allow-list; None when safe or not path-like.
    t = tok.strip("'\"")
    if not t or t.startswith(("&", "-", "/dev/")) or ("/" not in t and "." not in t):
        return None
    ap = os.path.abspath(os.path.join(BASE_CWD, os.path.expanduser(t)))
    if (ap + "/").startswith(WT_ROOT + "/"):
        return None
    if (ap + "/").startswith(WT_ROOT.split(MARK, 1)[0] + "/.claude-tmp/"):
        return None  # MAIN-anchored apex scratch (sanctioned side-channel)
    if any((ap + "/").startswith(s) for s in SCRATCH):
        return None
    return ap

REDIR = re.compile(r"(?<![<>])>{1,2}\s*([^\s;|&<>]+)")
GIT_WRITE = ("add", "commit", "apply", "am", "merge", "rebase", "cherry-pick",
             "revert", "restore", "checkout", "switch", "reset", "rm", "mv",
             "clean", "stash", "tag", "push")

def check_tree_writes(seg):
    # Fence tripwire for Bash file writes (the fence hook covers only the
    # four edit tools). Conservative: only path-like targets are classified.
    if WT_ROOT is None:
        return
    targets = REDIR.findall(seg)
    targets += re.findall(r"\btee\s+(?:-[a-zA-Z]+\s+)*([^\s;|&]+)", seg)
    if re.search(r"\bsed\b", seg) and re.search(r"(?:^|\s)-i", seg):
        targets += [t for t in seg.split() if t.startswith("/")]
    m = re.match(r"(?:cp|mv)\s+(.+)$", seg)
    if m:
        args = [t for t in m.group(1).split() if not t.startswith("-")]
        if len(args) >= 2:
            targets.append(args[-1])
    for tok in targets:
        ap = escapes_fence(tok)
        if ap:
            deny("Bash write to " + ap + " escapes the apex worktree." + fence_hint())

def check_git_tree(seg):
    # Benign-form git mutations against a tree outside the fence: git -C /
    # --work-tree pointing elsewhere, or plain git writes from an unanchored
    # (record-armed) context whose effective tree is the main checkout.
    if WT_ROOT is None:
        return
    m = re.match(r"git((?:\s+-[cC]\s+\S+|\s+--(?:git-dir|work-tree)(?:=\S+|\s+\S+))*)"
                 r"\s+([a-zA-Z-]+)", seg)
    if not m or m.group(2) not in GIT_WRITE:
        return
    pm = (re.search(r"-C\s+(\S+)", m.group(1))
          or re.search(r"--work-tree[=\s](\S+)", m.group(1)))
    root = pm.group(1).strip("'\"") if pm else BASE_CWD
    ap = os.path.abspath(os.path.join(BASE_CWD, os.path.expanduser(root)))
    if not (ap + "/").startswith(WT_ROOT + "/"):
        deny("git " + m.group(2) + " targets a tree outside the apex worktree ("
             + ap + ")." + fence_hint())

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
    # --- worktree-fence tripwire (armed apex sessions only) ---
    check_git_tree(s)
    check_tree_writes(s)
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
