#!/usr/bin/env python3
"""Step 6.a merge: layer JSONL files -> findings-{session}.json.

Spec: apex-core.md step 6.a (merge / dedupe / confidence / zero-layer).

Reads per-layer JSONL files from <layer_dir>:
    static-imports.jsonl, ast-grep.jsonl, framework.jsonl, ripgrep.jsonl
Each line: {"file": <realpath>, "detail": <str>, "line_range": null | [int, int]}.

Dedupe rules:
  - File entries deduped by `file` (already realpath-canonicalized at emit time).
  - Same-layer duplicates collapsed by (layer, detail) tuple.

Confidence:
  - 3 deterministic layers (static-imports/ast-grep/framework) -> high
  - 1-2 deterministic                                          -> medium
  - ripgrep-only                                               -> low
  - rescout layer is reserved for 7.x merge; never appears here.

_meta.warnings:
  - "no deterministic layers ran - ripgrep-only fallback" when layers 1-3 = 0
    AND ripgrep emitted at least one finding
  - "no layers produced findings" on the zero-layer case

Exit codes:
  0  - findings written
  1  - schema validation failed
  10 - zero-layer (script wrote empty findings + warning)

Args:
  --layer-dir PATH     (required) - tempdir with per-layer JSONL files
  --output PATH        (required) - findings-{session}.json target
  --det-nonempty 0|1   (required) - 1 if any of layers 1-4 emitted >=1 finding
  --rg-fired 0|1       (required) - 1 if layer 5 was invoked AND emitted >=1
"""
from __future__ import annotations
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402

LAYERS = ["static-imports", "ast-grep", "framework", "ripgrep"]
DETERMINISTIC = {"static-imports", "ast-grep", "framework"}

# Post-merge noise filter (step 6.a). Drops auto-generated / binary-shaped /
# lockfile-shaped paths that any layer might emit but the screener (6.c) and
# verify (8) would always discard. Keeping them out at merge time cuts shard
# fan-out, screener token cost, and LLM noise. Mirrors and complements the
# rg / grep glob excludes in _enumerate.py - this is the safety net for the
# ast-grep / framework / static-imports layers (and for ripgrep when a glob
# slips through). Source-shaped extensions (ts/tsx/js/jsx/py/md/json/svg/html
# /css/yaml/toml/sh/rb/go/rs/etc.) are NEVER in this set - the rule is "drop
# if clearly not human-edited source", not an extension allowlist.
NOISE_EXTENSIONS = frozenset({
    "lock", "map", "log",
    "pyc", "pyo", "pyd",
    "class", "jar", "war", "ear",
    "so", "dylib", "dll", "exe",
    "o", "a", "lib", "bin",
    "png", "jpg", "jpeg", "gif", "ico", "webp", "bmp", "tiff", "psd",
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
    "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
    "woff", "woff2", "ttf", "otf", "eot",
    "mp4", "webm", "mov", "avi", "mkv",
    "wav", "mp3", "ogg", "flac", "aac",
    "sqlite", "sqlite3", "db", "mdb",
})
NOISE_BASENAMES = frozenset({
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    "Cargo.lock", "Gemfile.lock", "composer.lock", "poetry.lock",
})


def is_noise_path(path: str) -> bool:
    base = os.path.basename(path)
    if base in NOISE_BASENAMES:
        return True
    # multi-dot suffixes (e.g., foo.min.js, bar.spec.snap)
    if base.endswith(".min.js") or base.endswith(".min.css"):
        return True
    if "." not in base:
        return False
    return base.rsplit(".", 1)[1].lower() in NOISE_EXTENSIONS


def confidence_for(reasons: list[dict]) -> str:
    det_count = sum(1 for r in reasons if r["layer"] in DETERMINISTIC)
    if det_count >= 3:
        return "high"  # all 3 deterministic layers fired
    if det_count >= 1:
        return "medium"
    return "low"  # ripgrep-only


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--layer-dir", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--det-nonempty", required=True, type=int)
    ap.add_argument("--rg-fired", required=True, type=int)
    args = ap.parse_args()

    by_file: dict[str, dict] = {}
    ripgrep_emitted = False

    for layer in LAYERS:
        p = os.path.join(args.layer_dir, f"{layer}.jsonl")
        if not os.path.isfile(p):
            continue
        layer_emitted = False
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                file = obj.get("file")
                if not file:
                    continue
                entry = by_file.setdefault(file, {"file": file, "reasons": []})
                reason = {
                    "layer": layer,
                    "detail": obj.get("detail", ""),
                    "line_range": obj.get("line_range"),
                }
                if any(
                    r["layer"] == layer and r["detail"] == reason["detail"]
                    for r in entry["reasons"]
                ):
                    continue
                entry["reasons"].append(reason)
                layer_emitted = True
        if layer == "ripgrep" and layer_emitted:
            ripgrep_emitted = True

    findings: list[dict] = []
    noise_dropped = 0
    for entry in by_file.values():
        if is_noise_path(entry["file"]):
            noise_dropped += 1
            continue
        entry["confidence"] = confidence_for(entry["reasons"])
        findings.append(entry)

    warnings: list[str] = []
    if noise_dropped:
        warnings.append(f"noise-filter dropped {noise_dropped} path(s) (lockfile/sourcemap/binary/etc.)")
    if args.det_nonempty == 0 and ripgrep_emitted:
        warnings.append("no deterministic layers ran - ripgrep-only fallback")

    zero_layer = len(findings) == 0
    if zero_layer:
        warnings.append("no layers produced findings")

    doc: dict = {"findings": findings}
    if warnings:
        doc["_meta"] = {"warnings": warnings}

    try:
        _validate.producer_validate(doc, "findings")
    except _validate.ValidationError as e:
        print(f"_enumerate_merge.py: schema validation failed: {e}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    return 10 if zero_layer else 0


if __name__ == "__main__":
    sys.exit(main())
