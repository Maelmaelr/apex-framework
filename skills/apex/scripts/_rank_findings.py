#!/usr/bin/env python3
"""Step 6.b: deterministic ranker + top-K cap. Spec: apex-core.md step 6.b.

Reads findings-{session}.json, applies optional --min-confidence filter,
scores each entry via deterministic formula, sorts desc, caps at top-K,
emits screen-plan-{session}.json with ranked list + screening prompt +
_meta telemetry.

Replaces the prior shard-fanout model: there is exactly one screener call
at 6.c that consumes screen-plan-{session}.json end-to-end.

Score formula (deterministic):
  base    = {1 layer: 0.4, 2 layers: 0.7, 3 layers: 1.0} (deterministic-layer count)
  bonus   = path-token overlap with hypothesis (capped at 0.3)
  penalty = size penalty (>= 500 LOC: 0.1; >= 1500 LOC: 0.2)
  score   = clamp(base + bonus - penalty, 0, 1)

Args:
  --findings PATH        (required) - findings-{session}.json
  --hypothesis PATH      (required) - {session}-hypothesis.json
  --output PATH          (required) - screen-plan-{session}.json
  --min-confidence LEV   (optional) - medium|high (default medium = no filter)
  --top-k N              (optional) - cap on ranked[] (default 30)

Exit codes: 0 = success | 11 = top-K cap overshot (dropped_below_cap >= top_k) | 1 = unrecoverable error
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402

DETERMINISTIC = {"static-imports", "ast-grep", "framework"}
DEFAULT_TOP_K = 30
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
STOPWORDS = {
    "the", "and", "for", "with", "from", "this", "that", "into",
    "are", "was", "were", "have", "had", "has", "been", "they", "them",
    "but", "not", "out", "off", "now", "via", "per", "etc",
    "when", "while", "where", "what", "which", "who", "how", "why",
    "your", "you", "our", "their", "his", "her", "its",
    "page", "site", "user", "data", "info", "file", "type",
    "name", "value", "state", "list", "item", "text",
    "title", "description", "content", "context",
    "true", "false", "null", "none",
    "more", "less", "than", "some", "any", "all", "many",
    "just", "like", "make", "made", "use", "using", "used",
    "stale", "fresh",
}


def hypothesis_tokens(hyp: dict) -> list[str]:
    text = (hyp.get("original_prompt", "") or "") + "\n" + (hyp.get("hypothesis", "") or "")
    seen: set[str] = set()
    out: list[str] = []
    for tok in TOKEN_RE.findall(text):
        low = tok.lower()
        if low in STOPWORDS or low in seen:
            continue
        seen.add(low)
        out.append(low)
    return out


def deterministic_layer_count(entry: dict) -> int:
    layers = {r.get("layer") for r in entry.get("reasons", []) if r.get("layer") in DETERMINISTIC}
    return len(layers)


def file_loc(path: str) -> int | None:
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return sum(1 for _ in f)
    except OSError:
        return None


def path_overlap(path: str, tokens: list[str]) -> float:
    if not tokens:
        return 0.0
    low = path.lower()
    matched = sum(1 for t in tokens if t in low)
    return min(0.3, matched / max(1, len(tokens)))


def size_penalty(loc: int | None) -> float:
    if loc is None or loc < 500:
        return 0.0
    if loc < 1500:
        return 0.1
    return 0.2


def score_breakdown(entry: dict, tokens: list[str]) -> dict:
    # Surfaces the deterministic formula components for cost-profiling
    # observation. Final score is clamp(base + bonus - penalty, 0, 1).
    n = deterministic_layer_count(entry)
    base = {1: 0.4, 2: 0.7, 3: 1.0}.get(n, 0.4)
    bonus = path_overlap(entry["file"], tokens)
    penalty = size_penalty(file_loc(entry["file"]))
    score = max(0.0, min(1.0, base + bonus - penalty))
    return {"base": base, "bonus": bonus, "penalty": penalty, "score": score}


def score_entry(entry: dict, tokens: list[str]) -> float:
    return score_breakdown(entry, tokens)["score"]


def screening_prompt(original_prompt: str, hypothesis: str) -> str:
    return f"""You are the apex step 6.c screener. A single deterministic-ranker pass at 6.b ranked the findings into one list (top-K cap applied; no shard fan-out). Your job: decide keep/drop per entry against the hypothesis.

## Hypothesis (verbatim from {{session}}-hypothesis.json)

original_prompt:
{original_prompt}

hypothesis:
{hypothesis}

## Decision rules

Bias from confidence (forwarded from 6.a):
- confidence: medium -> judgment; tilt drop if no relevance signal
- confidence: high   -> keep unless clear negative

The ranker has already ordered entries by deterministic relevance; treat the top of the list as more likely keeps and the tail as more likely drops, but verify each against the hypothesis.

## Output

Write `.claude-tmp/scout/screened-{{session}}.json` directly (no per-shard intermediates):
  - kept[]:    {{file, screener_reason, reasons, confidence}}  (reasons + confidence forwarded VERBATIM from input)
  - dropped[]: {{file, screener_reason}}

Write trace `.claude-tmp/apex-active/{{session}}-traces/entryflow/screener-attempt-N.md`
  (kept/dropped narrative, one-line reason per drop). N=1 initial; N=2 on exit-2 6c re-run.

Return: JSON path + one-line status (e.g., "kept: 18, dropped: 12"). Never the findings body.
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--findings", required=True)
    ap.add_argument("--hypothesis", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--min-confidence", default="medium", choices=("medium", "high"))
    ap.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    args = ap.parse_args()

    if args.top_k < 1:
        print(f"_rank_findings.py: --top-k must be >= 1 (got {args.top_k})", file=sys.stderr)
        return 1

    findings_doc = _validate.consumer_load(args.findings, "findings")
    if findings_doc is None:
        print(f"_rank_findings.py: invalid or missing findings file: {args.findings}", file=sys.stderr)
        return 1

    all_entries = findings_doc.get("findings", [])
    findings_count = len(all_entries)

    order = {"medium": 0, "high": 1}
    min_rank = order[args.min_confidence]
    filtered = [e for e in all_entries if order.get(e.get("confidence", "medium"), 0) >= min_rank]
    filter_drop_count = findings_count - len(filtered)

    with open(args.hypothesis, encoding="utf-8") as f:
        hyp = json.load(f)
    tokens = hypothesis_tokens(hyp)

    deterministic_count = sum(1 for e in filtered if deterministic_layer_count(e) >= 1)

    breakdowns = [(score_breakdown(e, tokens), e) for e in filtered]
    breakdowns.sort(key=lambda x: x[0]["score"], reverse=True)
    truncated = breakdowns[: args.top_k]
    dropped_below_cap = max(0, len(breakdowns) - args.top_k)

    ranked = []
    for sb, e in truncated:
        ranked.append({
            "file": e["file"],
            "score": round(sb["score"], 4),
            "rationale": {
                "base": round(sb["base"], 4),
                "bonus": round(sb["bonus"], 4),
                "penalty": round(sb["penalty"], 4),
            },
            "reasons": e.get("reasons", []),
            "confidence": e.get("confidence", "medium"),
        })

    warnings: list[str] = []
    if filter_drop_count > 0:
        warnings.append(
            f"--min-confidence={args.min_confidence} dropped {filter_drop_count} of {findings_count} entries before ranking"
        )
    if dropped_below_cap > 0:
        warnings.append(
            f"top-K cap dropped {dropped_below_cap} entries below score threshold (hypothesis may be too broad)"
        )

    doc: dict = {
        "ranked": ranked,
        "screening_prompt": screening_prompt(hyp.get("original_prompt", ""), hyp.get("hypothesis", "")),
        "_meta": {
            "warnings": warnings,
            "findings_count": findings_count,
            "ranked_count": len(ranked),
            "dropped_below_cap": dropped_below_cap,
            "deterministic_count": deterministic_count,
            "min_confidence": args.min_confidence,
            "top_k": args.top_k,
        },
    }

    try:
        _validate.producer_validate(doc, "screen-plan")
    except _validate.ValidationError as e:
        print(f"_rank_findings.py: producer schema validation failed: {e}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    return 11 if dropped_below_cap >= args.top_k else 0


if __name__ == "__main__":
    sys.exit(main())
