#!/usr/bin/env python3
"""Step 6.a layered enumeration. Spec: apex-core.md step 6.a.

Runs deterministic layers only (static-imports, ast-grep, framework). The
ripgrep keyword fallback was retired: it generated noise that propagated
through 6.b sharding into expensive 6.c screener fan-out. When all three
deterministic layers are empty the merger emits the zero-layer sentinel
(exit code 10) so the orchestrator routes to zero-layer-extract or refine.

Writes per-layer JSONL into --layer-dir; caller (enumerate-scout.sh) invokes
_enumerate_merge.py to dedupe + write findings-{session}.json.

Each JSONL line: {"file": <realpath>, "detail": <str>, "line_range": null|[s,e]}.

Args:
  --hypothesis PATH    (required) - {session}-hypothesis.json
  --layer-dir PATH     (required) - tempdir for per-layer JSONL output

Exit codes: 0 always (per-layer failures are absorbed; merger surfaces zero-layer).
"""
from __future__ import annotations
import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys

WORKSPACE_EXCLUDES = {
    "node_modules", ".next", ".turbo", "dist", "build", "out",
    ".git", ".vscode", "coverage", "__pycache__",
    "venv", "target",
}
SEED_TERM_CAP = 16
SUBPROCESS_TIMEOUT_S = 30
HEAD_FRAMEWORK = 200
HEAD_DJANGO_URLS = 50
HEAD_DJANGO_SETTINGS = 10

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


def extract_seeds(hypothesis_path: str) -> tuple[list[str], list[str]]:
    with open(hypothesis_path, encoding="utf-8") as f:
        hyp = json.load(f)
    text = (hyp.get("original_prompt", "") or "") + "\n" + (hyp.get("hypothesis", "") or "")

    path_re = re.compile(r"`([^`]+)`|\"([^\"]+)\"|([A-Za-z0-9_./\-]+\.[A-Za-z0-9]+)")
    seen: set[str] = set()
    seed_paths: list[str] = []
    for m in path_re.finditer(text):
        cand = next((g for g in m.groups() if g), "").strip()
        if not cand or cand in seen:
            continue
        seen.add(cand)
        if os.path.isfile(cand):
            seed_paths.append(cand)

    term_re = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
    seen_t: set[str] = set()
    seed_terms: list[str] = []
    for tok in term_re.findall(text):
        if tok.isdigit() or tok.lower() in STOPWORDS or tok in seen_t:
            continue
        if _is_english_word_shape(tok):
            continue
        seen_t.add(tok)
        seed_terms.append(tok)
        if len(seed_terms) >= SEED_TERM_CAP:
            break

    return seed_paths, seed_terms


def _is_english_word_shape(tok: str) -> bool:
    # Pure-lowercase 3-7 char alphabetic tokens are almost always English words,
    # not code identifiers. ast-grep --pattern wastes 30s timeouts on them
    # producing zero useful structural matches. Identifiers carry uppercase
    # (PascalCase / camelCase) or underscores (snake_case), or are long enough
    # (>= 8 chars) to be intentional symbol names.
    return tok.isalpha() and tok.islower() and 3 <= len(tok) <= 7


def emit(layer_dir: str, layer: str, file: str, detail: str, line_range: list[int] | None = None) -> None:
    canon = os.path.realpath(file) if os.path.exists(file) else file
    rec = {"file": canon, "detail": detail, "line_range": line_range}
    with open(os.path.join(layer_dir, f"{layer}.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def _walk(roots: list[str], accept_basename) -> list[str]:
    out: list[str] = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in WORKSPACE_EXCLUDES and not d.startswith(".")]
            for name in filenames:
                if accept_basename(name):
                    out.append(os.path.join(dirpath, name))
    return out


def _seed_filter(seed_terms: list[str]):
    lows = [t.lower() for t in seed_terms]
    if not lows:
        return lambda _p: True
    return lambda p: any(t in p.lower() for t in lows)


def layer_static_imports(layer_dir: str, seed_paths: list[str]) -> None:
    if shutil.which("madge"):
        for seed in seed_paths:
            if not seed.endswith((".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx")):
                continue
            try:
                proc = subprocess.run(
                    ["madge", "--json", seed],
                    capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_S,
                )
                data = json.loads(proc.stdout) if proc.returncode == 0 else None
            except (subprocess.SubprocessError, json.JSONDecodeError):
                data = None
            if not isinstance(data, dict):
                continue
            for k, vs in data.items():
                for path in [k] + list(vs or []):
                    emit(layer_dir, "static-imports", path, f"madge from {seed}")
    if shutil.which("pydeps"):
        for seed in seed_paths:
            if not seed.endswith(".py"):
                continue
            try:
                proc = subprocess.run(
                    ["pydeps", "--no-output", "--show-deps", seed],
                    capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_S,
                )
                data = ast.literal_eval(proc.stdout) if proc.returncode == 0 else None
            except (subprocess.SubprocessError, SyntaxError, ValueError):
                data = None
            if not isinstance(data, dict):
                continue
            for mod, info in data.items():
                path = (info or {}).get("path") if isinstance(info, dict) else None
                if path and os.path.isfile(path):
                    emit(layer_dir, "static-imports", path, f"pydeps from {seed} ({mod})")


def layer_ast_grep(layer_dir: str, seed_terms: list[str]) -> None:
    sg_bin = shutil.which("sg") or shutil.which("ast-grep")
    if not sg_bin:
        return
    for term in seed_terms:
        try:
            proc = subprocess.run(
                [sg_bin, "run", "--pattern", term, "--json=stream"],
                capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_S,
            )
        except subprocess.SubprocessError:
            continue
        if proc.returncode != 0:
            continue
        for ln in proc.stdout.splitlines():
            try:
                obj = json.loads(ln)
            except json.JSONDecodeError:
                continue
            path = obj.get("file") or obj.get("filename") or obj.get("path")
            if not path or not os.path.isfile(path):
                continue
            rng = obj.get("range") or {}
            start = (rng.get("start") or {}).get("line")
            end = (rng.get("end") or {}).get("line", start)
            line_range = [start + 1, end + 1] if isinstance(start, int) else None
            emit(layer_dir, "ast-grep", path, f"ast-grep '{term}'", line_range)


def layer_framework(layer_dir: str, seed_terms: list[str]) -> None:
    matches_seed = _seed_filter(seed_terms)

    APP_PREFIXES = ("page.", "layout.", "route.", "error.", "loading.", "not-found.", "template.", "default.")
    PAGES_EXTS = (".tsx", ".jsx", ".ts", ".js")

    app_route = lambda n: any(n.startswith(p) for p in APP_PREFIXES)
    for f in [x for x in _walk(["app", "src/app"], app_route) if matches_seed(x)][:HEAD_FRAMEWORK]:
        emit(layer_dir, "framework", f, "next.js app-router route")

    pages_route = lambda n: n.endswith(PAGES_EXTS)
    for f in [x for x in _walk(["pages", "src/pages"], pages_route) if matches_seed(x)][:HEAD_FRAMEWORK]:
        emit(layer_dir, "framework", f, "next.js pages-router route")

    if os.path.isfile("config/routes.rb"):
        emit(layer_dir, "framework", "config/routes.rb", "rails routes")
        for f in [x for x in _walk(["app/controllers", "app/models", "app/views"], lambda _: True) if matches_seed(x)][:HEAD_FRAMEWORK]:
            emit(layer_dir, "framework", f, "rails")

    for f in _walk(["."], lambda n: n == "urls.py")[:HEAD_DJANGO_URLS]:
        emit(layer_dir, "framework", f, "django urls")
    if os.path.isfile("manage.py"):
        for f in _walk(["."], lambda n: n == "settings.py")[:HEAD_DJANGO_SETTINGS]:
            emit(layer_dir, "framework", f, "django settings")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hypothesis", required=True)
    ap.add_argument("--layer-dir", required=True)
    args = ap.parse_args()

    os.makedirs(args.layer_dir, exist_ok=True)

    seed_paths, seed_terms = extract_seeds(args.hypothesis)

    layer_static_imports(args.layer_dir, seed_paths)
    layer_ast_grep(args.layer_dir, seed_terms)
    layer_framework(args.layer_dir, seed_terms)

    return 0


if __name__ == "__main__":
    sys.exit(main())
