#!/usr/bin/env bash
# SessionStart hook: apex state context injection at session boundaries.
# See user-global CLAUDE.md "Compaction Preservation" rule.
#
# Wired in settings.json under hooks.SessionStart with matcher="compact|resume":
#   - matcher=compact: fires after auto/manual compaction completes; re-injects
#     apex critical state so it survives the compaction summary.
#   - matcher=resume:  fires on /resume, --resume, --continue; re-injects state
#     so a resumed session has the apex artifact pointers immediately.
#   (matcher=startup and matcher=clear are NOT wired - no apex session active
#    at brand-new startup, and /clear explicitly drops state.)
#
# Why SessionStart and not PreCompact/PostCompact: per https://code.claude.com/
# docs/en/hooks.md, only PreToolUse / UserPromptSubmit / PostToolUse accept
# hookSpecificOutput.additionalContext. PreCompact has only top-level decision:
# block; PostCompact has no decision control at all; StopFailure ignores output.
# SessionStart matcher=compact is the canonical post-compaction injection point.
#
# State source: live read of .claude-tmp/apex-active/{session}.json (manifest),
# {session}-hypothesis.json, {session}-main-scope.json, plus
# .claude-tmp/scout/preflight-{session}.json. Stateless re-derivation matches
# scope-check-hook.sh; no snapshot file is written.
#
# Resolution: stdin session_id (Claude Code uuid) -> manifest where
# cc_session_id or p2_cc_session_id matches -> apex {session} 8-hex token.
# No match -> pass-through (entry-flow before manifest, or non-apex session).
#
# Hook protocol: always exit 0. Context injection is advisory; never blocks.

set -euo pipefail

APEX_ACTIVE=".claude-tmp/apex-active"

# Fast-path: skip the python parse on every SessionStart outside an apex
# session. No manifest can match without the dir; emit no output (matches
# pass-through behaviour for non-matching events).
[[ -d "$APEX_ACTIVE" ]] || exit 0

INPUT=$(cat 2>/dev/null || true)

# Parse hook event name + cc session_id + source in one Python pass.
# `source` is SessionStart's matcher trigger: startup|resume|clear|compact.
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get('hook_event_name') or d.get('event_name') or '')
print(d.get('session_id', ''))
print(d.get('source', ''))
" 2>/dev/null || true)

EVENT=$(printf '%s\n' "$PARSED" | sed -n '1p')
SESSION_ID=$(printf '%s\n' "$PARSED" | sed -n '2p')
SOURCE=$(printf '%s\n' "$PARSED" | sed -n '3p')

# Only act on SessionStart with matcher compact|resume. Other matchers
# (startup, clear) and other events are pass-through.
if [[ "$EVENT" != "SessionStart" ]] || [[ "$SOURCE" != "compact" && "$SOURCE" != "resume" ]]; then
  exit 0
fi

# Locate matching apex manifest. The manifest filename pattern is exactly 8 hex
# chars + .json (e.g. 1a2b3c4d.json); a stricter glob avoids -hypothesis.json,
# -main-scope.json, etc.
APEX_SESSION=""
MANIFEST=""
if [[ -n "$SESSION_ID" && -d "$APEX_ACTIVE" ]]; then
  shopt -s nullglob
  for m in "$APEX_ACTIVE"/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].json; do
    matched=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
sid = sys.argv[2]
if d.get('cc_session_id') == sid or d.get('p2_cc_session_id') == sid:
    print(d.get('session', ''))
" "$m" "$SESSION_ID" 2>/dev/null || true)
    if [[ -n "$matched" ]]; then
      APEX_SESSION="$matched"
      MANIFEST="$m"
      break
    fi
  done
  shopt -u nullglob
fi

# No matching manifest -> non-apex SessionStart. Exit silently.
if [[ -z "$APEX_SESSION" ]]; then
  exit 0
fi

HYPOTHESIS="$APEX_ACTIVE/$APEX_SESSION-hypothesis.json"
MAIN_SCOPE="$APEX_ACTIVE/$APEX_SESSION-main-scope.json"
PREFLIGHT=".claude-tmp/scout/preflight-$APEX_SESSION.json"
SCREENED=".claude-tmp/scout/screened-$APEX_SESSION.json"

OUTPUT=$(SOURCE="$SOURCE" \
         APEX_SESSION="$APEX_SESSION" \
         MANIFEST="$MANIFEST" \
         HYPOTHESIS="$HYPOTHESIS" \
         MAIN_SCOPE="$MAIN_SCOPE" \
         PREFLIGHT="$PREFLIGHT" \
         SCREENED="$SCREENED" \
         python3 <<'PY'
import json, os, time

source = os.environ.get("SOURCE") or "compact"
session = os.environ["APEX_SESSION"]
manifest = os.environ["MANIFEST"]
hypothesis = os.environ["HYPOTHESIS"]
main_scope = os.environ["MAIN_SCOPE"]
preflight = os.environ["PREFLIGHT"]
screened = os.environ["SCREENED"]

prefix = {
    "compact": "Re-injecting apex state after compaction:",
    "resume":  "Re-injecting apex state on session resume:",
}.get(source, "Apex state snapshot:")

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def truncate(s, n):
    s = (s or "").strip().replace("\n", " ")
    return s if len(s) <= n else s[: n - 3] + "..."

# task description
hyp = load(hypothesis) or {}
task_desc = truncate(hyp.get("original_prompt") or hyp.get("hypothesis") or "<unknown>", 200)

# session start (manifest mtime - manifest schema has no created_at field)
try:
    session_start = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(os.path.getmtime(manifest)))
except Exception:
    session_start = "<unknown>"

# apex path (Path 1/2 from preflight.mode)
pre = load(preflight)
if pre:
    mode = pre.get("mode")
    apex_path = {"medium": "Path 1 (medium)", "complex": "Path 2 (complex)"}.get(mode, f"<unrecognized mode: {mode}>")
else:
    apex_path = "<undecided - preflight not yet written>"

# active step (heuristic from artifact presence)
step = "step 2 (manifest written)"
if os.path.isfile(hypothesis):
    step = "step 3+ (hypothesis written)"
if os.path.isfile(preflight):
    step = "step 7+ (preflight written)"
if os.path.isfile(main_scope):
    step = "scope written (post step 5/8); execution phase"

# file ownership claims
ms = load(main_scope)
if ms:
    files = ms.get("allowed_files") or []
    head = files[:3]
    extra = "" if len(files) <= 3 else f" (+{len(files) - 3} more)"
    ownership = f"{len(files)} files{extra}: {head}"
else:
    ownership = "<no scope written yet>"

# scout findings file
if os.path.isfile(preflight):
    scout_path = preflight
elif os.path.isfile(screened):
    scout_path = screened
else:
    scout_path = "<no scout findings yet>"

block = "\n".join([
    "== APEX state preservation ==",
    prefix,
    f"apex session: {session}",
    f"task: {task_desc}",
    f"session start (manifest mtime): {session_start}",
    f"apex path: {apex_path}",
    f"active step: {step}",
    f"file ownership: {ownership}",
    f"scout findings: {scout_path}",
    "tail mode: <computed at p1.3/p2.4 from baseline>",
    "user decisions: <not persisted; scroll back to recover>",
    "== /APEX state preservation ==",
])

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": block,
    }
}))
PY
) || true

if [[ -z "$OUTPUT" ]]; then
  exit 0
fi

printf '%s\n' "$OUTPUT"
exit 0
