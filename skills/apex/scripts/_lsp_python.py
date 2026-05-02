#!/usr/bin/env python3
"""Python LSP adapter for scout 6.a layer_lsp.

Spec: apex-core.md step 6.a; design from admin-apex run e199ee86 (deferred
finding scout-6a-lsp-layer). Spawns pyright-langserver --stdio and issues
workspace/symbol queries for identifier-shape seed terms. Silent absorb on
failure: returns empty findings list + warnings strings.

Pyright is commonly installed via pip3 --user, which lands at
~/Library/Python/<ver>/bin on macOS - typically NOT on PATH. find_server
augments shutil.which with a small candidate list before giving up.

Project-root detection: walk up from cwd until pyproject.toml, setup.py, or
setup.cfg appears (capped at 6 levels). Python repos without any of those
return None and the layer skips silently (Python-less repo is not a failure).
"""
from __future__ import annotations
import os
import shutil
import sys
from typing import Any

from _lsp_client import query_symbols

PY_SERVER_BIN = "pyright-langserver"
PY_SERVER_ARGS = ["--stdio"]
ROOT_MARKERS = ("pyproject.toml", "setup.py", "setup.cfg")
ROOT_WALK_CAP = 6

# pip3 install --user lands binaries here on macOS / Linux; check after
# shutil.which because the user may not have ~/Library/Python/<ver>/bin on PATH.
PYRIGHT_FALLBACK_DIRS = (
    os.path.expanduser(f"~/Library/Python/{sys.version_info.major}.{sys.version_info.minor}/bin"),
    os.path.expanduser("~/.local/bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
)


def find_project_root(start: str) -> str | None:
    cur = os.path.abspath(start)
    for _ in range(ROOT_WALK_CAP):
        for marker in ROOT_MARKERS:
            if os.path.isfile(os.path.join(cur, marker)):
                return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent
    return None


def find_server() -> list[str] | None:
    bin_path = shutil.which(PY_SERVER_BIN)
    if not bin_path:
        for d in PYRIGHT_FALLBACK_DIRS:
            cand = os.path.join(d, PY_SERVER_BIN)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                bin_path = cand
                break
    if not bin_path:
        return None
    return [bin_path] + PY_SERVER_ARGS


def enumerate(seed_terms: list[str]) -> tuple[list[dict[str, Any]], list[str]]:
    server = find_server()
    if not server:
        return [], []
    root = find_project_root(os.getcwd())
    if root is None:
        return [], []
    queries = [t for t in seed_terms if _is_lsp_shape(t)]
    if not queries:
        return [], []
    return query_symbols(server, root, queries)


def _is_lsp_shape(tok: str) -> bool:
    if len(tok) < 3:
        return False
    if "_" in tok:
        return True
    if any(c.isupper() for c in tok):
        return True
    return False


if __name__ == "__main__":
    import json
    syms, warns = enumerate(sys.argv[1:])
    json.dump({"symbols": syms, "warnings": warns}, sys.stdout, indent=2)
    sys.stdout.write("\n")
