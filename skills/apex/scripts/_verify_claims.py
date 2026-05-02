#!/usr/bin/env python3
"""Step 8 verify-claims helper. Producer of {session}-main-scope.json on the normal path.

Spec: apex-core.md step 8 + Conventions / verify-claims.sh modes.

Default mode (no --apply-resolved):
  Reads screened-{session}.json + preflight-{session}.json. For each kept claim,
  checks file exists and (when present) line_range is in-bounds + non-empty.
  Drops mechanically-failed claims; tracks per-layer drop counts on screened
  (_meta.dropped_per_layer) and a single dropped_count on preflight (_meta).

  Confidence-aware screening: kept claims with confidence:low AND no line_range
  on any reason are removed from screened.kept and emitted to claim-review.json
  for the orchestrator's optional inline review (the unresolved batch).

  Exit-code priority 1 > 2 > 3 > 0:
    1 abort         preflight_bad >= 2 (abort_cause=preflight_bad)
                    OR rerun cap reached when exit-2 would re-fire (abort_cause=screened_unconverged)
    2 re-run 6c+7   screened_bad >= 3 OR rate >= 30%; cap 1 via {session}-verify-rerun.json
    3 inline review len(unresolved) >= 3; scope unwritten
    0 proceed       scope written; small-batch unresolveds (<3) stay dropped

--apply-resolved mode:
  Re-reads screened-{session}.json + claim-review-{session}.json + claim-review-resolved-{session}.json.
  For each resolved entry with action:keep, looks up the original claim (preserved
  in claim-review.json via the _original extra field) and re-adds it to screened.kept.
  Then unconditionally writes {session}-main-scope.json (exits 0).

The claim-review.json schema does not forbid additionalProperties, so the
_original field round-trips through schema validation untouched.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _validate  # noqa: E402

LAYERS = ["static-imports", "ast-grep", "framework", "ripgrep", "rescout"]
SCOUT_DIR = ".claude-tmp/scout"
APEX_ACTIVE = ".claude-tmp/apex-active"


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safety_paths(session: str) -> list[str]:
    # Closed set per shared-guardrails.md "Standard safety paths"; never includes
    # .env* or .git/. Keep in sync with zero-layer-extract.sh:89 (bash inline copy).
    return [".claude-tmp/", "~/.claude/tmp/", "~/.claude/plans/", f"/tmp/{session}-*", "docs/", "README*"]


def _line_range_ok(path: str, line_range) -> bool:
    if line_range is None:
        return True
    try:
        start, end = line_range
    except (TypeError, ValueError):
        return False
    if not (isinstance(start, int) and isinstance(end, int)) or start < 1 or end < start:
        return False
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return False
    if end > len(lines):
        return False
    # non-empty: at least one non-blank line in range
    return any(line.strip() for line in lines[start - 1 : end])


def _layers_for_claim(claim: dict) -> list[str]:
    return [r.get("layer") for r in claim.get("reasons", []) if r.get("layer")]


def _verify_kept_claim(claim: dict) -> bool:
    path = claim["file"]
    if not os.path.isfile(path):
        return False
    for reason in claim.get("reasons", []):
        if not _line_range_ok(path, reason.get("line_range")):
            return False
    return True


def _verify_missed_region(region: dict) -> bool:
    path = region["file"]
    if not os.path.isfile(path):
        return False
    return _line_range_ok(path, region.get("line_range"))


def _has_any_line_range(claim: dict) -> bool:
    return any(r.get("line_range") for r in claim.get("reasons", []))


def _build_review_entry(claim: dict) -> dict:
    # Preserves the full original kept-claim shape under _original for --apply-resolved
    # lookup. Schema does not set additionalProperties:false, so the extra field
    # passes producer/consumer validation unchanged.
    entry: dict = {
        "file": claim["file"],
        "reason": claim.get("screener_reason", ""),
        "_original": claim,
    }
    conf = claim.get("confidence")
    if conf in ("high", "medium", "low"):
        entry["confidence"] = conf
    lr = next((r.get("line_range") for r in claim.get("reasons", []) if r.get("line_range")), None)
    if lr is not None:
        entry["line_range"] = lr
    return entry


def _write_main_scope(session: str, screened: dict, produced_by: str) -> int:
    files = [c["file"] for c in screened.get("kept", [])]
    safety = _safety_paths(session)
    # Preserve order, de-dupe so safety paths don't duplicate file entries by accident.
    seen: set[str] = set()
    allowed: list[str] = []
    for f in files + safety:
        if f not in seen:
            seen.add(f)
            allowed.append(f)
    scope = {
        "session": session,
        "allowed_files": allowed,
        "produced_by": produced_by,
        "produced_at": _now(),
    }
    try:
        _validate.producer_validate(scope, "main-scope")
    except _validate.ValidationError as e:
        print(f"verify-claims.sh: main-scope schema invalid: {e}", file=sys.stderr)
        return 1
    scope_path = f"{APEX_ACTIVE}/{session}-main-scope.json"
    os.makedirs(os.path.dirname(scope_path), exist_ok=True)
    with open(scope_path, "w", encoding="utf-8") as f:
        json.dump(scope, f, indent=2)
    return 0


def cmd_verify(session: str) -> int:
    screened_path = f"{SCOUT_DIR}/screened-{session}.json"
    preflight_path = f"{SCOUT_DIR}/preflight-{session}.json"
    rerun_path = f"{APEX_ACTIVE}/{session}-verify-rerun.json"
    review_path = f"{SCOUT_DIR}/claim-review-{session}.json"

    screened = _validate.consumer_load(screened_path, "screened")
    if screened is None:
        # Upstream 6.c produced no valid screened doc; re-running won't help -> screened_unconverged.
        print(f"verify-claims.sh: screened missing or invalid: {screened_path}", file=sys.stderr)
        print("abort_cause=screened_unconverged", file=sys.stderr)
        return 1

    preflight = _validate.consumer_load(preflight_path, "preflight")
    if preflight is None:
        # Step 7 produced no valid preflight; mode/missed_regions are unknown -> preflight_bad.
        print(f"verify-claims.sh: preflight missing or invalid: {preflight_path}", file=sys.stderr)
        print("abort_cause=preflight_bad", file=sys.stderr)
        return 1

    kept_in = list(screened.get("kept", []))
    total_screened = len(kept_in)
    kept_passed: list[dict] = []
    kept_dropped: list[dict] = []
    dropped_per_layer = {layer: 0 for layer in LAYERS}

    for claim in kept_in:
        if _verify_kept_claim(claim):
            kept_passed.append(claim)
        else:
            kept_dropped.append(claim)
            for layer in _layers_for_claim(claim):
                if layer in dropped_per_layer:
                    dropped_per_layer[layer] += 1

    # Confidence-aware screening: low-confidence + no line_range -> unresolved.
    unresolved: list[dict] = []
    final_kept: list[dict] = []
    for claim in kept_passed:
        if claim.get("confidence") == "low" and not _has_any_line_range(claim):
            unresolved.append(claim)
        else:
            final_kept.append(claim)

    missed_in = list(preflight.get("missed_regions", []))
    missed_passed: list[dict] = []
    preflight_bad = 0
    for region in missed_in:
        if _verify_missed_region(region):
            missed_passed.append(region)
        else:
            preflight_bad += 1

    # Persist updated screened (stripped of dropped + unresolved) with per-layer counts.
    new_screened: dict = {"kept": final_kept, "dropped": list(screened.get("dropped", []))}
    if "_meta" in screened:
        new_screened["_meta"] = dict(screened["_meta"])
    new_screened.setdefault("_meta", {})["dropped_per_layer"] = dropped_per_layer
    try:
        _validate.producer_validate(new_screened, "screened")
    except _validate.ValidationError as e:
        print(f"verify-claims.sh: screened schema invalid post-update: {e}", file=sys.stderr)
        return 1
    with open(screened_path, "w", encoding="utf-8") as f:
        json.dump(new_screened, f, indent=2)

    # Persist updated preflight (mechanically-failed regions removed) with dropped_count.
    new_preflight = dict(preflight)
    new_preflight["missed_regions"] = missed_passed
    new_preflight.setdefault("_meta", {})["dropped_count"] = preflight_bad
    try:
        _validate.producer_validate(new_preflight, "preflight")
    except _validate.ValidationError as e:
        print(f"verify-claims.sh: preflight schema invalid post-update: {e}", file=sys.stderr)
        return 1
    with open(preflight_path, "w", encoding="utf-8") as f:
        json.dump(new_preflight, f, indent=2)

    # Emit (or remove stale) claim-review.json. Preserves full original claim under _original
    # so --apply-resolved can re-add the entry without lossy reconstruction.
    if unresolved:
        review_entries = [_build_review_entry(c) for c in unresolved]
        try:
            _validate.producer_validate(review_entries, "claim-review")
        except _validate.ValidationError as e:
            print(f"verify-claims.sh: claim-review schema invalid: {e}", file=sys.stderr)
            return 1
        with open(review_path, "w", encoding="utf-8") as f:
            json.dump(review_entries, f, indent=2)
    else:
        try:
            os.unlink(review_path)
        except FileNotFoundError:
            pass

    screened_bad = len(kept_dropped)
    screened_bad_rate = (screened_bad / total_screened) if total_screened > 0 else 0.0

    # Gate priority 1 > 2 > 3 > 0.
    if preflight_bad >= 2:
        print("abort_cause=preflight_bad", file=sys.stderr)
        return 1

    needs_rerun = (screened_bad >= 3) or (screened_bad_rate >= 0.30)
    if needs_rerun:
        rerun = _validate.consumer_load(rerun_path, "verify-rerun")
        prior_count = (rerun or {}).get("count", 0)
        if prior_count >= 1:
            print("abort_cause=screened_unconverged", file=sys.stderr)
            return 1
        new_rerun = {"count": 1, "last_attempt_at": _now()}
        try:
            _validate.producer_validate(new_rerun, "verify-rerun")
        except _validate.ValidationError as e:
            print(f"verify-claims.sh: verify-rerun schema invalid: {e}", file=sys.stderr)
            return 1
        with open(rerun_path, "w", encoding="utf-8") as f:
            json.dump(new_rerun, f, indent=2)
        return 2

    if len(unresolved) >= 3:
        # Scope intentionally unwritten; orchestrator runs inline review then re-invokes --apply-resolved.
        return 3

    return _write_main_scope(session, new_screened, "verify-claims.sh")


def cmd_apply_resolved(session: str) -> int:
    screened_path = f"{SCOUT_DIR}/screened-{session}.json"
    review_path = f"{SCOUT_DIR}/claim-review-{session}.json"
    resolved_path = f"{SCOUT_DIR}/claim-review-resolved-{session}.json"

    screened = _validate.consumer_load(screened_path, "screened")
    if screened is None:
        print(f"verify-claims.sh: screened missing or invalid: {screened_path}", file=sys.stderr)
        return 1

    resolved = _validate.consumer_load(resolved_path, "claim-review-resolved")
    if resolved is None:
        print(f"verify-claims.sh: claim-review-resolved missing or invalid: {resolved_path}", file=sys.stderr)
        return 1

    # claim-review.json may be absent if no unresolveds; then keep_files would also be empty.
    review = _validate.consumer_load(review_path, "claim-review") or []
    review_by_file: dict[str, dict] = {e["file"]: e for e in review}

    kept_now = list(screened.get("kept", []))
    seen_files = {c["file"] for c in kept_now}
    re_added: list[dict] = []
    for entry in resolved:
        if entry.get("action") != "keep":
            continue
        f = entry["file"]
        if f in seen_files:
            continue
        review_entry = review_by_file.get(f)
        if review_entry and "_original" in review_entry:
            re_added.append(review_entry["_original"])
        elif review_entry:
            # No _original captured (shouldn't happen with same-pipeline producer; defensive fallback).
            re_added.append(
                {
                    "file": f,
                    "screener_reason": review_entry.get("reason", ""),
                    "reasons": [],
                    "confidence": review_entry.get("confidence", "medium"),
                }
            )
        seen_files.add(f)

    new_kept = kept_now + re_added
    new_screened: dict = {"kept": new_kept, "dropped": list(screened.get("dropped", []))}
    if "_meta" in screened:
        new_screened["_meta"] = screened["_meta"]
    try:
        _validate.producer_validate(new_screened, "screened")
    except _validate.ValidationError as e:
        print(f"verify-claims.sh: screened schema invalid after apply-resolved: {e}", file=sys.stderr)
        return 1
    with open(screened_path, "w", encoding="utf-8") as f:
        json.dump(new_screened, f, indent=2)

    return _write_main_scope(session, new_screened, "verify-claims.sh --apply-resolved")


def main() -> int:
    # verify-claims.sh wrapper validates --session shape; this script trusts it.
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--apply-resolved", action="store_true")
    args = ap.parse_args()

    if args.apply_resolved:
        return cmd_apply_resolved(args.session)
    return cmd_verify(args.session)


if __name__ == "__main__":
    sys.exit(main())
