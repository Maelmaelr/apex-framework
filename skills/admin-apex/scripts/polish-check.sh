#!/usr/bin/env bash
# Purpose: post-implementation polish (staleness/inconsistency/unused) check.
# Spec: skills/admin-apex/sync-docs.md (admin-apex polish phase) +
#       skills/apex-improve/finalize.md (apex-improve polish phase).
#
# Re-snapshots inventory POST-apply, runs the orphan-refs / missing-refs /
# schema-mismatch / dead-hook detectors (mirrors audit.md), then diffs against
# the pre-apply drift report so only NEW issues introduced by the implementation
# surface. No-op when zero ops were applied this run.
#
# Args:
#   --run <RUN>   8-hex run token (required)
#
# Outputs:
#   .claude-tmp/admin-apex-active/{run}-inventory-post.json
#   .claude-tmp/admin-apex-active/{run}-polish-report.json
#
# Exit codes:
#   0   clean (or skipped because no ops applied)
#   1   new drift introduced; caller surfaces to user
#   2   bad args / state-corruption (caller aborts)

set -euo pipefail

RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    *) echo "Usage: polish-check.sh --run <RUN>" >&2; exit 2 ;;
  esac
done
[[ -n "$RUN" ]] || { echo "Usage: polish-check.sh --run <RUN>" >&2; exit 2; }

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/.claude}"
ACTIVE="$REPO_ROOT/.claude-tmp/admin-apex-active"
APPLIED="$ACTIVE/${RUN}-applied-ops.json"
DRIFT="$ACTIVE/${RUN}-drift-report.json"
INV_POST="$ACTIVE/${RUN}-inventory-post.json"
POLISH="$ACTIVE/${RUN}-polish-report.json"

# Skip when zero ops applied (nothing to polish).
OPCOUNT=0
if [[ -s "$APPLIED" ]]; then
  OPCOUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$APPLIED" 2>/dev/null || echo 0)
fi
if [[ "$OPCOUNT" -lt 1 ]]; then
  echo "polish-check: 0 ops applied; skip" >&2
  exit 0
fi

# Re-snapshot post-apply inventory (own snapshot - never share with task 2's).
bash "$REPO_ROOT/skills/admin-apex/scripts/inventory-apex.sh" --out "$INV_POST" >/dev/null

# Run polish detectors. Mirrors audit.md (orphan-refs / missing-refs /
# schema-mismatch / dead-hook). Diff against pre-apply drift -> only NEW items.
python3 - "$RUN" "$INV_POST" "$DRIFT" "$POLISH" <<'PYEOF'
import json, os, re, sys, datetime
from pathlib import Path

run, inv_path, drift_path, polish_path = sys.argv[1:5]
ROOT = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.path.expanduser("~/.claude")))
inv = json.loads(Path(inv_path).read_text())

inv_paths = set()
for k in ("skills", "agents", "scripts", "schemas", "spec_docs"):
    for e in inv.get(k, []):
        inv_paths.add(e["path"])

spec_bodies = {}
for sd in inv.get("spec_docs", []):
    p = ROOT / sd["path"]
    if p.exists():
        spec_bodies[sd["path"]] = p.read_text()
all_text = "\n".join(spec_bodies.values())

clusters = []

# orphan-refs (staleness)
ref_re = re.compile(r"\b(skills/apex/[^\s\)\`\"']+|skills/admin-apex/[^\s\)\`\"']+|agents/[^\s\)\`\"']+|scripts/[^\s\)\`\"']+)")
orphans = set()
for body in spec_bodies.values():
    for m in ref_re.findall(body):
        ref = m.rstrip(".,;:)")
        if "*" in ref or "?" in ref or ref.endswith("/"):
            continue
        if ref.startswith("scripts/"):
            tail = ref[len("scripts/"):]
            if (f"skills/apex/{ref}" in inv_paths
                    or f"skills/admin-apex/{ref}" in inv_paths
                    or any(p.endswith("/" + tail) for p in inv_paths)):
                continue
        if ref in inv_paths:
            continue
        if any(p.startswith(ref + "/") for p in inv_paths):
            continue
        orphans.add(ref)
if orphans:
    clusters.append({"id": "orphan", "kind": "staleness",
                     "items": sorted(orphans),
                     "summary": f"{len(orphans)} broken spec-doc ref(s) post-apply"})

# missing-refs (unused)
def is_referenced(p):
    bn = os.path.basename(p)
    if bn in all_text or p in all_text:
        return True
    par = os.path.dirname(p)
    while par and par != ".":
        if par + "/*" in all_text or par + "/" in all_text or par + "/**" in all_text:
            return True
        par = os.path.dirname(par)
    return False

def intra_skill(p):
    parts = p.split("/")
    if len(parts) < 3 or parts[0] != "skills":
        return False
    root = f"skills/{parts[1]}/"
    bn = os.path.basename(p)
    for sib in inv_paths:
        if sib == p or not sib.startswith(root):
            continue
        sp = ROOT / sib
        if sp.exists():
            try:
                body = sp.read_text()
                if bn in body or p in body:
                    return True
            except Exception:
                pass
    if p.startswith("skills/apex/"):
        for sib in inv_paths:
            if not (sib.startswith("skills/apex-") or sib.startswith("skills/admin-apex/")):
                continue
            sp = ROOT / sib
            if sp.exists():
                try:
                    body = sp.read_text()
                    if bn in body or p in body:
                        return True
                except Exception:
                    pass
    return False

missing = []
for k in ("skills", "agents", "scripts", "schemas"):
    for e in inv.get(k, []):
        p, bn = e["path"], os.path.basename(e["path"])
        if bn == "SKILL.md" or "__pycache__" in p or bn.startswith("_"):
            continue
        if is_referenced(p) or intra_skill(p):
            continue
        missing.append(p)
if missing:
    clusters.append({"id": "missing", "kind": "unused",
                     "items": missing,
                     "summary": f"{len(missing)} inventory file(s) with zero spec-doc reference post-apply"})

# schema-mismatch + dead-hook (inconsistency)
mism = [f"{s['path']} (id={s.get('id')})"
        for s in inv.get("schemas", []) if s.get("id") != os.path.basename(s["path"])]
if mism:
    clusters.append({"id": "schema", "kind": "inconsistency",
                     "items": mism,
                     "summary": f"{len(mism)} schema id != basename post-apply"})

dead = []
for h in inv.get("hooks", []):
    cmd = h.get("command", "")
    for m in re.findall(r"(?:\$\{CLAUDE_PROJECT_DIR\}|~/\.claude|/Users/[^\s]+/\.claude)/([^\s]+\.(?:sh|py))", cmd):
        if not (ROOT / m).exists():
            dead.append(f"{h.get('event')}: {m}")
if dead:
    clusters.append({"id": "dead-hook", "kind": "inconsistency",
                     "items": dead,
                     "summary": f"{len(dead)} hook(s) point to missing scripts post-apply"})

# Diff against pre-apply drift -> surface only NEW items per cluster id.
prior = {}
if os.path.exists(drift_path):
    try:
        for c in json.loads(Path(drift_path).read_text()).get("clusters", []):
            prior[c["id"]] = set(c.get("items", []))
    except Exception:
        pass

new_clusters = []
for c in clusters:
    new_items = [i for i in c["items"] if i not in prior.get(c["id"], set())]
    if new_items:
        nc = dict(c)
        nc["items"] = new_items
        nc["summary"] = f"{len(new_items)} new {c['kind']} introduced by apply"
        new_clusters.append(nc)

out = {
    "run": run,
    "clusters": new_clusters,
    "_meta": {"generated_at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")}
}
Path(polish_path).write_text(json.dumps(out, indent=2) + "\n")
print(polish_path)
sys.exit(1 if new_clusters else 0)
PYEOF
