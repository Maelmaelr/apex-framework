#!/usr/bin/env python3
"""Shared deterministic detector engine for the apex framework.

Spec: skills/admin-apex/audit.md (task 3 structural pre-scan) +
      skills/admin-apex/scripts/polish-check.sh (post-apply NEW-only diff).

Consumes a {run}-inventory.json (schemas/inventory.schema.json) and emits a
clusters JSON envelope ({run, clusters, _meta}). The detector core is identical
across both callers - only the cluster vocabulary, the oversized inclusion, and
the prior-drift diff differ by --mode:

  --mode audit   Structural pre-scan for audit.md task 3. Runs oversized-files /
                 orphan-refs / missing-refs / schema-mismatch / dead-hook with
                 audit.md's cluster vocabulary (kinds: oversized-files /
                 orphan-refs / missing-refs / schema-mismatch / dead-hook; ids:
                 oversized / orphan / missing / schema / dead-hook). No
                 prior-drift diff. The LLM-owned stale-spec + user-driven
                 detectors stay in audit.md prose and are merged after the
                 structural clusters via --extra-clusters. Always exits 0 (drift
                 is the normal case; the SKILL task-4 gate, not the exit code,
                 drives keep/apply/defer).

  --mode polish  Post-apply mirror for polish-check.sh. Runs orphan-refs /
                 missing-refs / schema-mismatch / dead-hook (NO oversized -
                 line-cap remediation is owned by /apex verify + file-health,
                 not the post-apply polish gate). Uses polish vocabulary (kinds:
                 staleness / unused / inconsistency; ids: orphan / missing /
                 schema / dead-hook - ids match audit mode so --prior-drift
                 diffs line up). Diffs against --prior-drift so only NEW items
                 introduced by the apply surface. Exits 1 when any NEW cluster
                 remains (caller surfaces to user), else 0.

CLI:
  audit-detectors.py --inventory <path> --mode {audit|polish} --run <RUN>
                     [--prior-drift <path>]    # polish NEW-only diff source
                     [--extra-clusters <path>] # audit: LLM stale-spec/user-driven to append
                     [--out <path>]            # write here; else stdout

Exit codes:
  0  audit mode (always), or polish mode with no NEW drift
  1  polish mode with NEW drift introduced by the apply
  2  bad args / unreadable inventory (argparse or explicit)
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

PROSE_DOCS = {"apex-core.md", "apex-core-overview.md", "README.md", "CLAUDE.md"}

# Spec-doc reference extractor (mirrors audit.md orphan-refs detector).
REF_RE = re.compile(
    r"\b(skills/apex/[^\s\)\`\"']+|skills/admin-apex/[^\s\)\`\"']+"
    r"|agents/[^\s\)\`\"']+|scripts/[^\s\)\`\"']+)"
)
HOOK_RE = re.compile(
    r"(?:\$\{CLAUDE_PROJECT_DIR\}|~/\.claude|/Users/[^\s]+/\.claude)/([^\s]+\.(?:sh|py))"
)


def inventory_path_set(inv):
    paths = set()
    for k in ("skills", "agents", "scripts", "schemas", "spec_docs"):
        for e in inv.get(k, []):
            paths.add(e["path"])
    return paths


def read_spec_bodies(inv, root):
    bodies = {}
    for sd in inv.get("spec_docs", []):
        p = root / sd["path"]
        if p.exists():
            bodies[sd["path"]] = p.read_text()
    return bodies


def detect_oversized(inv):
    """audit-only. skills/agents .md cap 175; scripts cap 500; prose docs cap 800."""
    items = []
    for e in inv.get("skills", []) + inv.get("agents", []):
        if e["lines"] > 175:
            items.append(f'{e["path"]} ({e["lines"]} lines)')
    for e in inv.get("scripts", []):
        if e["lines"] > 500:
            items.append(f'{e["path"]} ({e["lines"]} lines)')
    for e in inv.get("spec_docs", []):
        cap = 800 if os.path.basename(e["path"]) in PROSE_DOCS else 500
        if e["lines"] > cap:
            items.append(f'{e["path"]} ({e["lines"]} lines)')
    return items


def detect_orphans(inv_paths, bodies):
    """Spec-doc refs with no inventory match (with shorthand/glob/dir exceptions)."""
    orphans = set()
    for body in bodies.values():
        for m in REF_RE.findall(body):
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
    return sorted(orphans)


def detect_missing(inv, inv_paths, bodies, root):
    """Inventory files with zero spec-doc reference (intra-skill + cross-apex covered)."""
    all_text = "\n".join(bodies.values())

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

    def referenced_by_any(p, candidates):
        bn = os.path.basename(p)
        for sib in candidates:
            sp = root / sib
            if not sp.exists():
                continue
            try:
                body = sp.read_text()
            except OSError:
                continue
            if bn in body or p in body:
                return True
        return False

    def intra_skill(p):
        parts = p.split("/")
        if len(parts) < 3 or parts[0] != "skills":
            return False
        skill_root = f"skills/{parts[1]}/"
        siblings = [s for s in inv_paths if s != p and s.startswith(skill_root)]
        if referenced_by_any(p, siblings):
            return True
        if p.startswith("skills/apex/"):
            cross = [s for s in inv_paths
                     if s.startswith("skills/apex-") or s.startswith("skills/admin-apex/")]
            if referenced_by_any(p, cross):
                return True
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
    return missing


def detect_schema_mismatch(inv):
    return [f"{s['path']} (id={s.get('id')})"
            for s in inv.get("schemas", []) if s.get("id") != os.path.basename(s["path"])]


def detect_dead_hooks(inv, root):
    dead = []
    for h in inv.get("hooks", []):
        for m in HOOK_RE.findall(h.get("command", "")):
            if not (root / m).exists():
                dead.append(f"{h.get('event')}: {m}")
    return dead


# (id, audit-kind, polish-kind, audit-summary, polish-summary) per structural detector.
_SPEC = {
    "oversized": ("oversized-files", None,
                  "{n} file(s) over line cap", None),
    "orphan": ("orphan-refs", "staleness",
               "{n} spec-doc ref(s) with no inventory match",
               "{n} broken spec-doc ref(s) post-apply"),
    "missing": ("missing-refs", "unused",
                "{n} inventory file(s) with zero spec-doc reference",
                "{n} inventory file(s) with zero spec-doc reference post-apply"),
    "schema": ("schema-mismatch", "inconsistency",
               "{n} schema id != basename",
               "{n} schema id != basename post-apply"),
    "dead-hook": ("dead-hook", "inconsistency",
                  "{n} hook(s) point to missing scripts",
                  "{n} hook(s) point to missing scripts post-apply"),
}


def build_cluster(cid, items, mode):
    audit_kind, polish_kind, audit_sum, polish_sum = _SPEC[cid]
    kind = audit_kind if mode == "audit" else polish_kind
    summary = (audit_sum if mode == "audit" else polish_sum).format(n=len(items))
    return {"id": cid, "kind": kind, "items": items, "summary": summary}


def diff_against_prior(clusters, prior_path):
    """polish-only NEW-item diff keyed on cluster id."""
    prior = {}
    if prior_path and os.path.exists(prior_path):
        try:
            for c in json.loads(Path(prior_path).read_text()).get("clusters", []):
                prior[c["id"]] = set(c.get("items", []))
        except (OSError, json.JSONDecodeError, KeyError):
            pass
    new_clusters = []
    for c in clusters:
        new_items = [i for i in c["items"] if i not in prior.get(c["id"], set())]
        if new_items:
            nc = dict(c)
            nc["items"] = new_items
            nc["summary"] = f"{len(new_items)} new {c['kind']} introduced by apply"
            new_clusters.append(nc)
    return new_clusters


def main():
    ap = argparse.ArgumentParser(description="Deterministic apex drift detector engine.")
    ap.add_argument("--inventory", required=True, help="path to {run}-inventory.json")
    ap.add_argument("--mode", required=True, choices=["audit", "polish"])
    ap.add_argument("--run", required=True, help="8-hex run token")
    ap.add_argument("--prior-drift", help="polish: pre-apply drift report for NEW-only diff")
    ap.add_argument("--extra-clusters", help="audit: JSON array of LLM stale-spec/user-driven clusters to append")
    ap.add_argument("--out", help="write report here; otherwise stdout")
    args = ap.parse_args()

    root = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.path.expanduser("~/.claude")))
    try:
        inv = json.loads(Path(args.inventory).read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"audit-detectors: cannot read inventory {args.inventory}: {e}", file=sys.stderr)
        sys.exit(2)

    inv_paths = inventory_path_set(inv)
    bodies = read_spec_bodies(inv, root)

    detected = {
        "orphan": detect_orphans(inv_paths, bodies),
        "missing": detect_missing(inv, inv_paths, bodies, root),
        "schema": detect_schema_mismatch(inv),
        "dead-hook": detect_dead_hooks(inv, root),
    }
    if args.mode == "audit":
        detected = {"oversized": detect_oversized(inv), **detected}

    order = ["oversized", "orphan", "missing", "schema", "dead-hook"]
    clusters = [build_cluster(cid, detected[cid], args.mode)
                for cid in order if cid in detected and detected[cid]]

    if args.mode == "polish":
        clusters = diff_against_prior(clusters, args.prior_drift)
    elif args.extra_clusters and os.path.exists(args.extra_clusters):
        try:
            extra = json.loads(Path(args.extra_clusters).read_text())
            if isinstance(extra, list):
                clusters.extend(extra)
        except (OSError, json.JSONDecodeError):
            pass

    out = {
        "run": args.run,
        "clusters": clusters,
        "_meta": {"generated_at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")},
    }
    payload = json.dumps(out, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(payload)
        print(args.out)
    else:
        sys.stdout.write(payload)

    sys.exit(1 if (args.mode == "polish" and clusters) else 0)


if __name__ == "__main__":
    main()
