#!/usr/bin/env bash
# Purpose: fixtures for scripts/audit-detectors.py (the shared detector engine
#          A1 extracted from polish-check.sh + audit.md).
# Spec: skills/admin-apex/audit.md task 3 + scripts/polish-check.sh.
#
# Kept separate from test-apex-scripts.sh (which is already near the 400-line
# file-health cap) - that harness invokes this one and folds the result.
# Also runnable standalone.
#
# Exit codes: 0 all fixtures pass; 1 one or more failed.

set -uo pipefail
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
ENG="$REPO_ROOT/skills/admin-apex/scripts/audit-detectors.py"
pass=0
failed=0

check() {  # label expected-exit got-exit
  if [[ "$3" == "$2" ]]; then
    echo "PASS $1 (exit=$3)"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected $2, got $3)" >&2; failed=$((failed + 1))
  fi
}

# Synthetic inventory exercising the structural detectors without disk reads
# (oversized = doc word-budget compare; schema-mismatch = pure id-vs-basename).
INV_DRIFT='{"skills":[{"path":"skills/apex/big.md","lines":222,"words":3000}],"agents":[],"scripts":[],"schemas":[{"path":"skills/apex/schemas/x.schema.json","id":"WRONG.json"}],"hooks":[],"spec_docs":[],"version":"0"}'
INV_SCHEMA='{"skills":[],"agents":[],"scripts":[],"schemas":[{"path":"skills/apex/schemas/x.schema.json","id":"WRONG.json"}],"hooks":[],"spec_docs":[],"version":"0"}'

# 1. Missing --mode -> argparse usage error, exit 2.
python3 "$ENG" --inventory /tmp/x --run abcd1234 >/dev/null 2>&1
check "missing-mode exit2" 2 $?

# 2. audit mode: oversized + schema-mismatch detected; --extra-clusters appended LAST.
inv=$(mktemp); extra=$(mktemp)
printf '%s' "$INV_DRIFT" > "$inv"
printf '%s' '[{"id":"user-driven","kind":"user-driven","items":["skills/apex/foo.md"],"summary":"c"}]' > "$extra"
out=$(python3 "$ENG" --inventory "$inv" --mode audit --run abcd1234 --extra-clusters "$extra" 2>/dev/null)
AD_OUT="$out" python3 -c '
import json, os, sys
k = [c["kind"] for c in json.loads(os.environ["AD_OUT"])["clusters"]]
sys.exit(0 if ("oversized-files" in k and "schema-mismatch" in k and k and k[-1] == "user-driven") else 1)
'
check "audit detect+merge" 0 $?
rm -f "$inv" "$extra"

# 3. polish mode: schema mismatch, empty prior -> NEW drift -> exit 1.
inv=$(mktemp); prior=$(mktemp); out=$(mktemp)
printf '%s' "$INV_SCHEMA" > "$inv"
printf '%s' '{"run":"x","clusters":[]}' > "$prior"
python3 "$ENG" --inventory "$inv" --mode polish --run abcd1234 --prior-drift "$prior" --out "$out" >/dev/null 2>&1
check "polish new-drift exit1" 1 $?
rm -f "$inv" "$prior" "$out"

# 4. polish mode: every detected item already in prior drift -> diff suppresses -> exit 0.
#    The lone unreferenced schema entry trips BOTH schema-mismatch and missing-refs,
#    so the prior must carry both ids for the NEW-only diff to net empty. Isolated
#    root (no content-budget.json) so hash-roster reads no live docs and cannot
#    inject a spurious NEW cluster from the real tree's citation state.
inv=$(mktemp); prior=$(mktemp); out=$(mktemp); isoroot=$(mktemp -d)
printf '%s' "$INV_SCHEMA" > "$inv"
{
  printf '{"run":"x","clusters":['
  printf '{"id":"schema","kind":"inconsistency","items":["skills/apex/schemas/x.schema.json (id=WRONG.json)"]},'
  printf '{"id":"missing","kind":"unused","items":["skills/apex/schemas/x.schema.json"]}]}'
} > "$prior"
CLAUDE_PROJECT_DIR="$isoroot" python3 "$ENG" --inventory "$inv" --mode polish --run abcd1234 \
  --prior-drift "$prior" --out "$out" >/dev/null 2>&1
check "polish no-new-drift exit0" 0 $?
rm -f "$inv" "$prior" "$out"; rm -rf "$isoroot"

# --- per-role content-budget tier + approaching-budget (reads content-budget.json) ---
RUN=abcd1234
t=$(mktemp)

mkinv() {  # $1=path $2=words -> single-skill inventory on $t
  python3 - "$1" "$2" > "$t" <<'PY'
import json, sys
print(json.dumps({"skills": [{"path": sys.argv[1], "words": int(sys.argv[2])}],
                  "agents": [], "scripts": [], "schemas": [], "hooks": [],
                  "spec_docs": [], "version": "0"}))
PY
}

inband() {  # $1=engine-out $2=cluster-id $3=path -> exit 0 if path appears in that cluster
  AD="$1" CID="$2" P="$3" python3 -c '
import json, os, sys
cs = {c["id"]: c["items"] for c in json.loads(os.environ["AD"])["clusters"]}
sys.exit(0 if any(os.environ["P"] in i for i in cs.get(os.environ["CID"], [])) else 1)
'
}

# 5. tier: executor.md 3900 < 4000 tier (non-exempt) -> NOT oversized, but IS approaching (98%).
mkinv "agents/executor.md" 3900
out=$(python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" oversized "agents/executor.md"; o=$?
inband "$out" approaching "agents/executor.md"; a=$?
[[ $o -ne 0 && $a -eq 0 ]]; check "tier executor.md 3900 pass+approaching" 0 $?

# 5b. near_cap_exempt: apex/SKILL.md 6900 sits in the band (0.85*7000<6900<=7000) but is
#     exempt (plan-pinned dense) -> NOT approaching, and still NOT oversized.
mkinv "skills/apex/SKILL.md" 6900
out=$(python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" approaching "skills/apex/SKILL.md"; a=$?
inband "$out" oversized "skills/apex/SKILL.md"; o=$?
[[ $a -ne 0 && $o -ne 0 ]]; check "exempt SKILL.md 6900 no-approaching" 0 $?

# 6. tier: apex/SKILL.md 7100 > 7000 tier -> oversized (exempt skips approaching, never oversized).
mkinv "skills/apex/SKILL.md" 7100
out=$(python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" oversized "skills/apex/SKILL.md"; check "tier SKILL.md 7100 oversized" 0 $?

# 7. default tier: a non-mapped skill .md at 2600 > 2500 default -> oversized.
mkinv "skills/apex-improve/SKILL.md" 2600
out=$(python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" oversized "skills/apex-improve/SKILL.md"; check "default 2600 oversized" 0 $?

# 8. approaching silent below the band: executor.md 2800 (70%) -> neither cluster.
mkinv "agents/executor.md" 2800
out=$(python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" approaching "agents/executor.md"; a=$?
inband "$out" oversized "agents/executor.md"; o=$?
[[ $a -ne 0 && $o -ne 0 ]]; check "approaching silent at 71%" 0 $?

# 9. fail-safe fallback: content-budget.json absent (empty CLAUDE_PROJECT_DIR) -> flat
#    2500 default, no error; a 3000-word skill .md flags oversized under the default.
fake=$(mktemp -d)
mkinv "skills/apex/SKILL.md" 3000
out=$(CLAUDE_PROJECT_DIR="$fake" python3 "$ENG" --inventory "$t" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" oversized "skills/apex/SKILL.md"; check "detector fallback flags 3000w at 2500" 0 $?
rm -rf "$fake"
rm -f "$t"

# --- hash-roster (A4 re-bloat guard): reads docs from disk per content-budget.json
#     hash_roster.{ceiling,docs}. Fake root so fixtures drive config + targets. ---
ti=$(mktemp)
printf '%s' '{"skills":[],"agents":[],"scripts":[],"schemas":[],"hooks":[],"spec_docs":[],"version":"0"}' > "$ti"

# 10. ceiling 0: a doc with reflector-hash citations flags; a citation-free doc does not.
hr=$(mktemp -d); mkdir -p "$hr/skills/apex/scripts" "$hr/agents"
cb="$hr/skills/apex/scripts/content-budget.json"
printf '%s' '{"hash_roster":{"ceiling":0,"docs":["agents/clean.md","agents/dirty.md"]}}' > "$cb"
printf 'a rule, no cite - a 4-session cluster escalated verbose reasons\n' > "$hr/agents/clean.md"
printf 'a rule (reflector 5ec98cfc, 33935c17); recurring cluster 006ab516/734e3faf\n' > "$hr/agents/dirty.md"
out=$(CLAUDE_PROJECT_DIR="$hr" python3 "$ENG" --inventory "$ti" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" hash-roster "agents/dirty.md"; d=$?
inband "$out" hash-roster "agents/clean.md"; c=$?
[[ $d -eq 0 && $c -ne 0 ]]; check "hash-roster flags dirty not clean" 0 $?
rm -rf "$hr"

# 11. ceiling slack: at ceiling N a doc with exactly N citations passes, N+1 flags.
hr=$(mktemp -d); mkdir -p "$hr/skills/apex/scripts" "$hr/agents"
cb="$hr/skills/apex/scripts/content-budget.json"
printf '%s' '{"hash_roster":{"ceiling":2,"docs":["agents/at.md","agents/over.md"]}}' > "$cb"
printf 'two cites (reflector 5ec98cfc, 33935c17) is at the ceiling\n' > "$hr/agents/at.md"
printf 'three (reflector 5ec98cfc, 33935c17, 87c0386e) is over ceiling\n' > "$hr/agents/over.md"
out=$(CLAUDE_PROJECT_DIR="$hr" python3 "$ENG" --inventory "$ti" --mode audit --run "$RUN" 2>/dev/null)
inband "$out" hash-roster "agents/over.md"; ov=$?
inband "$out" hash-roster "agents/at.md"; at=$?
[[ $ov -eq 0 && $at -ne 0 ]]; check "hash-roster ceiling slack at vs over" 0 $?
rm -rf "$hr"
rm -f "$ti"

# --- approaching NEW-diff path-keying (regression: recurred runs that nudged an
#     in-band file's word count). The polish NEW-only diff must key on FILE PATH,
#     not the volatile count-string, so a word delta (up OR down) on a file already
#     in the prior approaching band is NOT a false NEW; a file NEWLY entering the
#     band still surfaces. refs.md keeps missing/orphan-refs quiet so only the
#     approaching cluster is in play. ---
ak=$(mktemp -d); mkdir -p "$ak/skills/apex/scripts"
{
  printf '{"default":2500,"tiers":{"agents/executor.md":4000},'
  printf '"near_cap_ratio":0.85,"near_cap_exempt":[],"hash_roster":{"ceiling":0,"docs":[]}}'
} > "$ak/skills/apex/scripts/content-budget.json"
printf 'agents/executor.md\n' > "$ak/refs.md"
invp=$(mktemp); prior=$(mktemp); aout=$(mktemp)
{   # post-apply inventory: executor.md at 3700w (93% of 4000) -> in band.
  printf '{"skills":[],"agents":[{"path":"agents/executor.md","words":3700}],'
  printf '"scripts":[],"schemas":[],"hooks":[],"spec_docs":[{"path":"refs.md"}],"version":"0"}'
} > "$invp"

prior_at() {  # $1=words $2=pct -> 1-item approaching prior on $prior
  printf '{"run":"x","clusters":[{"id":"approaching","kind":"approaching-budget",' > "$prior"
  printf '"items":["agents/executor.md (%s words, %s%% of 4000 cap)"]}]}' "$1" "$2" >> "$prior"
}

# 12a. prior in-band at a HIGHER count (3900/98% -> 3700/93%, reduction) -> 0 NEW.
prior_at 3900 98
CLAUDE_PROJECT_DIR="$ak" python3 "$ENG" --inventory "$invp" --mode polish --run "$RUN" \
  --prior-drift "$prior" --out "$aout" >/dev/null 2>&1
check "approaching path-keyed: reduction is not NEW" 0 $?

# 12b. prior in-band at a LOWER count (3500/88% -> 3700/93%, increase) -> 0 NEW.
prior_at 3500 88
CLAUDE_PROJECT_DIR="$ak" python3 "$ENG" --inventory "$invp" --mode polish --run "$RUN" \
  --prior-drift "$prior" --out "$aout" >/dev/null 2>&1
check "approaching path-keyed: increase is not NEW" 0 $?

# 12c. file NOT in the prior band -> genuinely NEW (path-key must not over-suppress).
printf '%s' '{"run":"x","clusters":[]}' > "$prior"
CLAUDE_PROJECT_DIR="$ak" python3 "$ENG" --inventory "$invp" --mode polish --run "$RUN" \
  --prior-drift "$prior" --out "$aout" >/dev/null 2>&1
check "approaching path-keyed: new entrant still surfaces" 1 $?
rm -f "$invp" "$prior" "$aout"; rm -rf "$ak"

echo "test-audit-detectors.sh: pass=$pass fail=$failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
