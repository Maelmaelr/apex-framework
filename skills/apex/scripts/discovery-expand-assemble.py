#!/usr/bin/env python3
"""Assemble discovery-expand.sh's TSV accumulators into the output JSON.

Invoked by skills/apex/scripts/discovery-expand.sh (the bash driver does all
file discovery; this module owns JSON shaping - robust escaping, per-path
source dedup, match counting, ranking). Kept as a separate module so the bash
driver stays under the code line-count budget and the assembler gets its own
py_compile coverage in test-apex-scripts.sh.

Inputs (env vars, all paths to temp files the driver wrote):
  ACC       TSV  path<TAB>source   (one row per clause hit, existence-filtered)
  PRESPLIT  TSV  source<TAB>split_target<TAB>loc
  DOCSURF   one doc path per line
  DELONLY   one repo-relative path per line
  CAPS      comma-joined clause=cap pairs (e.g. importer=30,peermount=12)
argv[1]: output path, or /dev/stdout.

Spec: agents/discoverer.md (cascade layer b), skills/apex/steps/06-discovery.md.
"""
import json
import os
import sys
import collections


def uniq_lines(path):
    seen, out = set(), []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and line not in seen:
                    seen.add(line)
                    out.append(line)
    except FileNotFoundError:
        pass
    return out


def main():
    acc = os.environ["ACC"]
    presplit = os.environ["PRESPLIT"]
    docsurf = os.environ["DOCSURF"]
    delonly = os.environ["DELONLY"]
    out_path = sys.argv[1]

    cand = collections.OrderedDict()  # path -> {sources:set, match_count:int}
    with open(acc) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            path, _, src = line.partition("\t")
            if not path:
                continue
            e = cand.setdefault(path, {"sources": set(), "match_count": 0})
            e["sources"].add(src or "?")
            e["match_count"] += 1

    candidates = [
        {"path": p, "sources": sorted(v["sources"]), "match_count": v["match_count"]}
        for p, v in cand.items()
    ]
    # rank: more distinct sources first, then higher match count, then path.
    candidates.sort(key=lambda c: (-len(c["sources"]), -c["match_count"], c["path"]))

    presplit_targets = []
    seen_ps = set()
    try:
        with open(presplit) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3 and parts[0] not in seen_ps:
                    seen_ps.add(parts[0])
                    presplit_targets.append(
                        {"source": parts[0], "split_target": parts[1], "loc": int(parts[2])})
    except FileNotFoundError:
        pass

    caps = {}
    for pair in os.environ["CAPS"].split(","):
        k, _, v = pair.partition("=")
        hit = sum(1 for c in candidates if k in c["sources"])
        caps[k] = {"cap": int(v), "truncated": hit >= int(v)}

    result = {
        "candidates": candidates,
        "doc_surface": uniq_lines(docsurf),
        "presplit_targets": presplit_targets,
        "delete_only_hint": uniq_lines(delonly),
        "caps": caps,
    }
    data = json.dumps(result, indent=2)
    if out_path == "/dev/stdout":
        sys.stdout.write(data + "\n")
    else:
        with open(out_path, "w") as f:
            f.write(data + "\n")


if __name__ == "__main__":
    main()
