#!/usr/bin/env python3
"""Shared deterministic detector engine for the apex framework.

Spec: skills/admin-apex/audit.md (task 3) + scripts/polish-check.sh (post-apply
NEW-only diff). The audit.md drift-kind table is the source of truth for each
detector's rule; this module is its implementation. The detector core is shared;
--mode differs only in cluster vocabulary, the oversized inclusion, and the diff:

  --mode audit   Pre-scan: oversized-files / orphan-refs / missing-refs /
                 schema-mismatch / dead-hook / approaching-budget / hash-roster /
                 negative-scope. LLM-owned stale-spec + user-driven merge in via
                 --extra-clusters. Always exits 0 (the SKILL task-4 gate decides).
  --mode polish  Post-apply NEW-only mirror: same detectors minus oversized,
                 relabeled (staleness / unused / inconsistency; approaching +
                 hash-roster + negative-scope keep their kinds). Diffs against
                 --prior-drift; exits 1 when any NEW cluster remains.

CLI: --inventory <p> --mode {audit|polish} --run <RUN> [--prior-drift <p>]
[--extra-clusters <p>] [--out <p>] (argparse help below). Exit: 0 audit (always)
or polish-no-NEW; 1 polish-NEW; 2 bad args / unreadable inventory.
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

PROSE_DOCS = {"apex-core.md", "apex-core-overview.md", "README.md", "CLAUDE.md"}

# File-health content-budget caps. Docs gate on words (newline count is gamed by
# one-paragraph-per-line markdown); scripts gate on physical lines + longest line.
# Per-role word caps live in content-budget.json (shared with file-health-hook.sh);
# DOC_WORD_CAP / PROSE_WORD_CAP are the fail-safe fallback when it is unreadable.
DOC_WORD_CAP = 2500            # fallback default skills/agents .md content budget
PROSE_WORD_CAP = 11400         # fallback central-prose (apex-core/overview/README/CLAUDE) budget
SCRIPT_LINE_CAP = 500          # scripts: physical-line cap (source text, not prose)
MAX_LINE_LEN = 120             # scripts: longest single-line cap
CONTENT_BUDGET_PATH = "skills/apex/scripts/content-budget.json"

# Spec-doc reference extractor (mirrors audit.md orphan-refs detector).
REF_RE = re.compile(
    r"\b(skills/apex/[^\s\)\`\"']+|skills/admin-apex/[^\s\)\`\"']+"
    r"|agents/[^\s\)\`\"']+|scripts/[^\s\)\`\"']+)"
)
HOOK_RE = re.compile(
    r"(?:\$\{CLAUDE_PROJECT_DIR\}|~/\.claude|/Users/[^\s]+/\.claude)/([^\s]+\.(?:sh|py))"
)


def load_budget(root):
    """Per-role content-budget tiers; fail-safe to hardcoded caps when
    content-budget.json is missing/unparseable (a partial file merges over the
    fallback, so every key still resolves)."""
    fallback = {
        "default": DOC_WORD_CAP,
        "central_prose": PROSE_WORD_CAP,
        "tiers": {},
        "central_prose_members": sorted(PROSE_DOCS),
        "near_cap_ratio": 0.85,
        "near_cap_exempt": [],
        "hash_roster": {"ceiling": 0, "docs": []},
    }
    try:
        data = json.loads((root / CONTENT_BUDGET_PATH).read_text())
    except (OSError, json.JSONDecodeError):
        return fallback
    return {**fallback, **{k: data[k] for k in fallback if k in data}}


def cap_for(path, budget):
    """Resolve a doc path's word cap: explicit tier > central-prose member > default."""
    if path in budget["tiers"]:
        return budget["tiers"][path]
    if os.path.basename(path) in set(budget["central_prose_members"]):
        return budget["central_prose"]
    return budget["default"]


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


def _max_line_len(path):
    """Longest line length (newline stripped) for a script; 0 if unreadable."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return max((len(line.rstrip("\n")) for line in f), default=0)
    except OSError:
        return 0


def detect_oversized(inv, root, budget):
    """Audit-only oversized gate: docs over their per-role word cap (cap_for);
    scripts over SCRIPT_LINE_CAP lines or MAX_LINE_LEN longest line. See audit.md."""
    items = []
    for e in inv.get("skills", []) + inv.get("agents", []) + inv.get("spec_docs", []):
        words = e.get("words", 0)
        cap = cap_for(e["path"], budget)
        if words > cap:
            items.append(f'{e["path"]} ({words} words > {cap}; {e.get("lines", 0)} lines)')
    for e in inv.get("scripts", []):
        reasons = []
        if e["lines"] > SCRIPT_LINE_CAP:
            reasons.append(f'{e["lines"]} lines > {SCRIPT_LINE_CAP}')
        longest = _max_line_len(root / e["path"])
        if longest > MAX_LINE_LEN:
            reasons.append(f'longest line {longest} > {MAX_LINE_LEN}')
        if reasons:
            items.append(f'{e["path"]} ({"; ".join(reasons)})')
    return items


def detect_approaching(inv, budget):
    """skills/agents .md in the near-cap band (near_cap_ratio*cap, cap] - WARN-only
    leanness pressure before the hard oversized gate. near_cap_exempt paths
    (plan-pinned dense files) are skipped. See audit.md."""
    items = []
    ratio = budget["near_cap_ratio"]
    exempt = set(budget.get("near_cap_exempt", []))
    for e in inv.get("skills", []) + inv.get("agents", []):
        if e["path"] in exempt:
            continue
        words = e.get("words", 0)
        cap = cap_for(e["path"], budget)
        if ratio * cap < words <= cap:
            items.append(f'{e["path"]} ({words} words, {round(100 * words / cap)}% of {cap} cap)')
    return items


# Reflector-hash citation matcher (re-bloat guard). A "citation hash" is an 8-hex
# token led by a citation keyword (reflector/session/incident/cluster) or in a
# multi-hash roster (joined by / , + &); an isolated keyword-less hex is NOT
# counted, so false positives stay near zero.
_HASH = r"(?<![0-9a-z])[0-9a-f]{8}(?![0-9a-z])"
_KEYWORD_CITE = re.compile(
    r"\b(?:reflector|reflectors|session|sessions|incident|cluster|clusters)\b[ \t]+"
    + _HASH + r"(?:[ \t]*[/,+&][ \t]*" + _HASH + r")*"
)
_ROSTER_CITE = re.compile(_HASH + r"(?:[ \t]*[/,+&][ \t]*" + _HASH + r")+")
_HASH_RE = re.compile(_HASH)


def count_citation_hashes(text):
    """Count 8-hex tokens that read as reflector/session audit-trail citations."""
    spans = []
    for rx in (_KEYWORD_CITE, _ROSTER_CITE):
        spans.extend((m.start(), m.end()) for m in rx.finditer(text))
    return sum(1 for h in _HASH_RE.finditer(text)
               if any(s <= h.start() < e for s, e in spans))


# Negative-scope disclaimer matcher (re-bloat guard for the section/bullet half of
# apex-core.md Lean prose; hash-roster covers the inline-hash half). Flags a
# dedicated "What X does NOT do" / "Out of scope" / "Non-goals" HEADING or a
# THIRD-PERSON "Does NOT ..." bullet. Operational negatives that govern current
# behavior (imperative "Do not run X", "never blind-edit") read as second-person
# and never match - the anchored patterns are zero-false-positive.
_NEG_HEADING = re.compile(
    r"(?im)^#{1,6}[ \t]+(?:out[- ]of[- ]scope|non[- ]goals?"
    r"|what[ \t].+?does(?:n't| not)[ \t]+do)[ \t]*:?[ \t]*$")
_NEG_BULLET = re.compile(r"(?im)^[ \t]*[-*][ \t]+(?:does not|doesn't)[ \t]+")


def detect_negative_scope(inv, root):
    """skills/agents/spec .md carrying a negative-scope disclaimer (any hit is
    drift; zero-FP anchored patterns -> no roster/ceiling config). See audit.md."""
    items = []
    for e in inv.get("skills", []) + inv.get("agents", []) + inv.get("spec_docs", []):
        if not e["path"].endswith(".md"):
            continue
        try:
            text = (root / e["path"]).read_text()
        except OSError:
            continue
        n = len(_NEG_HEADING.findall(text)) + len(_NEG_BULLET.findall(text))
        if n:
            items.append(f'{e["path"]} ({n} negative-scope disclaimer(s))')
    return items


def detect_hash_roster(root, budget):
    """Runtime-loaded docs (content-budget.json hash_roster.docs) carrying
    reflector-hash citations above hash_roster.ceiling - re-bloat guard for the
    inline-hash half of apex-core.md Lean prose. Missing/empty config no-ops."""
    cfg = budget.get("hash_roster") or {}
    ceiling = cfg.get("ceiling", 0)
    items = []
    for rel in cfg.get("docs", []):
        try:
            n = count_citation_hashes((root / rel).read_text())
        except OSError:
            continue
        if n > ceiling:
            items.append(f"{rel} ({n} reflector-hash citation(s) > {ceiling} ceiling)")
    return items


def detect_orphans(inv_paths, bodies, root):
    """Spec-doc refs resolving to neither an inventory entry nor an on-disk file
    (after shorthand/glob/dir exceptions). Flags dead references, not inventory-
    membership gaps (missing-refs' job). See audit.md."""
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
            if (root / ref).exists():
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


_SPEC = {  # id -> (audit-kind, polish-kind, audit-summary, polish-summary)
    "oversized": ("oversized-files", None,
                  "{n} file(s) over content/size budget", None),
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
    "approaching": ("approaching-budget", "approaching-budget",
                    "{n} skills/agents .md within near-cap band (>= 85% of tier; WARN, never blocks)",
                    "{n} skills/agents .md newly within near-cap band post-apply (WARN)"),
    "hash-roster": ("hash-roster", "hash-roster",
                    "{n} runtime doc(s) carrying reflector-hash citations above ceiling (A4 re-bloat guard)",
                    "{n} runtime doc(s) with NEW reflector-hash citations post-apply (A4 re-bloat guard)"),
    "negative-scope": ("negative-scope", "negative-scope",
                       "{n} doc(s) carrying a negative-scope disclaimer section/bullet (re-bloat guard)",
                       "{n} doc(s) with a NEW negative-scope disclaimer post-apply (re-bloat guard)"),
}


def build_cluster(cid, items, mode):
    audit_kind, polish_kind, audit_sum, polish_sum = _SPEC[cid]
    kind = audit_kind if mode == "audit" else polish_kind
    summary = (audit_sum if mode == "audit" else polish_sum).format(n=len(items))
    return {"id": cid, "kind": kind, "items": items, "summary": summary}


def _diff_key(item):
    """NEW-diff identity: path/label before ' (', dropping the volatile count
    detail so a count delta on an unchanged path is not mis-reported as NEW."""
    return item.split(" (", 1)[0]


def diff_against_prior(clusters, prior_path):
    """polish-only NEW-item diff keyed on cluster id + per-item path key."""
    prior = {}
    if prior_path and os.path.exists(prior_path):
        try:
            for c in json.loads(Path(prior_path).read_text()).get("clusters", []):
                prior[c["id"]] = {_diff_key(i) for i in c.get("items", [])}
        except (OSError, json.JSONDecodeError, KeyError):
            pass
    new_clusters = []
    for c in clusters:
        new_items = [i for i in c["items"] if _diff_key(i) not in prior.get(c["id"], set())]
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
    budget = load_budget(root)

    detected = {
        "orphan": detect_orphans(inv_paths, bodies, root),
        "missing": detect_missing(inv, inv_paths, bodies, root),
        "schema": detect_schema_mismatch(inv),
        "dead-hook": detect_dead_hooks(inv, root),
        "approaching": detect_approaching(inv, budget),
        "hash-roster": detect_hash_roster(root, budget),
        "negative-scope": detect_negative_scope(inv, root),
    }
    if args.mode == "audit":
        detected = {"oversized": detect_oversized(inv, root, budget), **detected}

    order = ["oversized", "orphan", "missing", "schema", "dead-hook",
             "approaching", "hash-roster", "negative-scope"]
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
