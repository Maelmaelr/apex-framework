#!/usr/bin/env bash
# Orphan {token}-* artifact sweep for .claude-tmp/{apex-active,admin-apex-active}.
# Spec: apex-core.md Failure handling / "sweep-orphan-artifacts.sh".
#
# Cleans:
#   - Files matching <dir>/{token}-* where:
#       * {token} is 8-char lowercase hex (openssl rand -hex 4 shape)
#       * <dir>/{token}.json manifest is absent (orphaned: producer never wrote
#         the manifest, OR manifest was already swept while a sibling artifact
#         was left behind)
#       * artifact mtime is older than --age-hours threshold (defends against
#         a still-writing producer that has not yet finalized its manifest)
#
# EXEMPT (never reaped): {token}-deferred-findings.json. The apex-improve /
# admin-apex backlog is session-spanning and must persist across arbitrary idle
# gaps (user decision: keep backlog). analyze.md consumes + consolidates it and
# finalize.md prunes the consumed originals each run, so it never accumulates
# unbounded; previously the >24h idle-gap reap dropped it whenever the improve
# loop paused for a day.
#
# Why this exists (leak mode plugged):
#   - Crashed CC sessions can leave {session}-* siblings (inventory, drift-report,
#     traces, etc.) in apex-active / admin-apex-active when cleanup-session.sh /
#     cleanup-run.sh aborts before reaching every target. This sweep drains those
#     once their manifest is gone and they age past --age-hours.
#
# What it does NOT do:
#   - Does NOT touch {token}.json manifests (that's sweep-stale-runs.sh's
#     PID-rollover classifier).
#   - Does NOT touch {token}-* artifacts when the manifest is still present
#     (those are owned by the active run; cleanup-{run,session}.sh handles them).
#   - Does NOT touch artifacts younger than --age-hours (defends against
#     in-flight producers that have not yet written their manifest).
#   - Does NOT wipe a co-running run's live artifacts: the manifest-absent
#     branch re-checks {token}.json on disk just before deletion (TOCTOU
#     close). This guard still matters for admin-apex-active
#     where concurrent CC sessions can interleave; apex hot-path is worktree-
#     resident so the surface is narrow but the guard is cheap.
#
# Args:
#   --dir <path>           (required) - .claude-tmp/apex-active OR
#                                       .claude-tmp/admin-apex-active. Absolute
#                                       path or relative to caller cwd.
#   --age-hours <N>        (optional; default 24) - Skip artifacts younger than
#                          N hours. 0 disables the guard (use only in tests).
#
# Exit code: always 0 (best-effort; warnings to stderr).

# Intentionally NOT using `set -e`: cleanup is best-effort. A single rm failure
# (permission, race) must not abort remaining sweeps. Per-target failures
# surface to stderr via warn() while the script continues.
set -uo pipefail

DIR=""
AGE_HOURS=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      DIR="${2:-}"
      shift 2
      ;;
    --age-hours)
      AGE_HOURS="${2:-}"
      shift 2
      ;;
    *)
      echo "sweep-orphan-artifacts.sh: unknown arg: $1" >&2
      exit 0
      ;;
  esac
done

if [[ -z "$DIR" ]]; then
  echo "sweep-orphan-artifacts.sh: --dir is required" >&2
  exit 0
fi

if ! [[ "$AGE_HOURS" =~ ^[0-9]+$ ]]; then
  echo "sweep-orphan-artifacts.sh: --age-hours must be a non-negative integer (got: $AGE_HOURS)" >&2
  exit 0
fi

[[ -d "$DIR" ]] || exit 0

warn() {
  echo "sweep-orphan-artifacts.sh: $*" >&2
}

NOW=$(date +%s)
THRESHOLD_SEC=$(( AGE_HOURS * 3600 ))

# Single python pass enumerates orphan {token}-* artifacts. Bash collects the
# list and removes them. Python is the right tool for the listdir + regex +
# manifest-existence check; bash for the rm + warn.
# Pipe, NOT `done < <(...)` process substitution: bash 3.2 (macOS /bin/bash
# 3.2.57) mis-scans a heredoc body nested in `<(...)` at RUNTIME and aborts
# "bad substitution", silently reaping nothing under `2>/dev/null || true`
# callers. The failure is content-dependent (the heredoc body's paren balance)
# and `bash -n` parses it cleanly, so it is invisible to syntax checks - the
# regression test in test-sweep.sh therefore RUNS the script under bash 3.2,
# not just `bash -n`. The while body keeps no state (rm + warn only), so the
# pipe subshell is harmless.
python3 - "$DIR" "$NOW" "$THRESHOLD_SEC" <<'PY' |
import os, re, sys
d = sys.argv[1]
now = int(sys.argv[2])
threshold = int(sys.argv[3])
if not os.path.isdir(d):
    sys.exit(0)
# 8-hex token followed by '-'; everything after the dash is the artifact
# kind suffix (e.g., -deferred-findings.json, -inventory.json, -traces/...).
pat = re.compile(r"^([0-9a-f]{8})-")
try:
    names = sorted(os.listdir(d))
except OSError:
    sys.exit(0)
manifests = set()
for n in names:
    if re.match(r"^[0-9a-f]{8}\.json$", n):
        manifests.add(n[:-5])
for name in names:
    m = pat.match(name)
    if not m:
        continue
    # EXEMPT: the session-spanning {token}-deferred-findings.json backlog must
    # persist across arbitrary idle gaps (user decision: keep backlog, never
    # reap). analyze.md consumes + consolidates it and finalize.md prunes the
    # consumed originals every run, so steady state holds at most one file - it
    # never accumulates unbounded. Skipping it here removes the >24h idle-gap
    # reap that previously dropped the backlog when the improve loop paused.
    if name.endswith("-deferred-findings.json"):
        continue
    tok = m.group(1)
    # Manifest still present -> active run owns this artifact; skip.
    if tok in manifests:
        continue
    full = os.path.join(d, name)
    try:
        st = os.stat(full)
    except OSError:
        continue
    age = now - int(st.st_mtime)
    if threshold > 0 and age < threshold:
        continue
    # Just-in-time manifest re-check: a co-running run may write its
    # {token}.json between listdir() above and this point. Without this
    # re-stat a concurrent sweep wiped a live run's artifacts mid-flow
    # Re-check on disk closes the TOCTOU window so a
    # live run that just armed its manifest is never swept.
    if os.path.exists(os.path.join(d, tok + ".json")):
        continue
    print(full)
PY
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  rm -f -- "$f" 2>/dev/null || warn "failed to remove: $f"
done

exit 0
