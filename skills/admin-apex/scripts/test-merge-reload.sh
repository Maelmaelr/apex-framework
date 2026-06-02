#!/usr/bin/env bash
# Purpose: fixtures for skills/apex-merge/scripts/merge-loop.sh per-iteration
#          reload reminder (Workstream B item-4 / B/item-6). Asserts merge-loop.sh
#          emits one "Read skills/apex-merge/resolve-one-conflict.md" reminder per
#          remaining conflicted file on exit 20, and none on a clean merge.
# Spec: apex-context-rot-optimization plan "Item 4 design - apex-merge per-iteration
#       contract reload"; skills/apex-merge/SKILL.md step 4.
#
# Kept separate from test-apex-scripts.sh (near the 400-line file-health cap),
# which invokes this one and folds the result. Also runnable standalone.
#
# Each case builds a throwaway git repo (HOME overridden so merge-loop.sh's
# $HOME/.claude/.claude-tmp/apex-merge-active resolves into the sandbox), forks an
# apex/<token> branch with a controlled conflict shape, runs merge-loop.sh, and
# asserts the exit code + reminder count. Conflicts are forced onto the content
# (resolver) path via UNBALANCED-bracket apex-side content so merge-loop.sh's
# trivial-union pass rejects them (the reminder only fires for remaining files).
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
MERGE_LOOP="$REPO_ROOT/skills/apex-merge/scripts/merge-loop.sh"
REMINDER='Read skills/apex-merge/resolve-one-conflict.md before resolving'
TOKEN="feedf00d"
pass=0
failed=0

# Build a git sandbox: repo=$1, HOME=$2, conflict-file count=$3 (0|1|2). Leaves
# the repo checked out on a clean main with an apex/<token> branch to merge.
setup_repo() {
  local repo="$1" thome="$2" nconf="$3"
  ( cd "$repo"
    export HOME="$thome"
    git init -q -b main .
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'alpha\n' > a.txt; printf 'beta\n' > b.txt; printf 'gamma\n' > c.txt
    git add -A; git commit -q -m c0
    git branch "apex/$TOKEN"
    printf 'alpha-main\n' > a.txt; printf 'beta-main\n' > b.txt
    git add -A; git commit -q -m c1-main
    git checkout -q "apex/$TOKEN"
    case "$nconf" in
      2) printf 'alpha-apex (\n' > a.txt; printf 'beta-apex [\n' > b.txt ;;
      1) printf 'alpha-apex (\n' > a.txt ;;
      0) printf 'gamma-apex\n' > c.txt ;;
    esac
    git add -A; git commit -q -m c1-apex
    git checkout -q main
  ) >/dev/null 2>&1
}

run_case() {  # label expected_exit expected_reminders nconf
  local label="$1" exp_exit="$2" exp_rem="$3" nconf="$4"
  local thome repo run="abcd1234" out rc rem
  thome=$(mktemp -d); repo=$(mktemp -d)
  setup_repo "$repo" "$thome" "$nconf"
  mkdir -p "$thome/.claude/.claude-tmp/apex-merge-active"
  printf '{"branches":[{"branch":"apex/%s","base":"main","subject":"t","status":"needs-merge"}]}\n' \
    "$TOKEN" > "$thome/.claude/.claude-tmp/apex-merge-active/$run-discovery.json"
  out=$( cd "$repo" && HOME="$thome" bash "$MERGE_LOOP" "$run" 2>/dev/null )
  rc=$?
  rem=$(printf '%s\n' "$out" | grep -c "$REMINDER")
  rm -rf "$thome" "$repo"
  if [[ "$rc" == "$exp_exit" && "$rem" == "$exp_rem" ]]; then
    echo "PASS $label (exit=$rc reminders=$rem)"; pass=$((pass + 1))
  else
    { echo "FAIL $label"; echo "    expected exit=$exp_exit reminders=$exp_rem; got exit=$rc reminders=$rem"; } >&2
    failed=$((failed + 1))
  fi
}

run_case "clean-merge emits no reminder" 0 0 0
run_case "1 conflict file -> reminder once" 20 1 1
run_case "2 conflict files -> reminder twice" 20 2 2

echo ""
echo "test-merge-reload.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
