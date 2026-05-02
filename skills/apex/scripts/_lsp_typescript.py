#!/usr/bin/env python3
"""TypeScript LSP adapter for scout 6.a layer_lsp.

Spec: apex-core.md step 6.a; design from admin-apex run e199ee86 (deferred
finding scout-6a-lsp-layer). Spawns typescript-language-server --stdio and
issues workspace/symbol queries for identifier-shape seed terms. Silent absorb
on any failure: returns empty findings list + warnings strings.

Project-root detection: walk up from cwd until tsconfig.json or package.json
is found (capped at 6 levels). Returns None when no TS-shaped root - the
caller should skip the layer with no warning (TS-less repo is not a failure).
"""
from __future__ import annotations
import os
import shutil
from typing import Any

from _lsp_client import query_symbols

TS_SERVER_BIN = "typescript-language-server"
TS_SERVER_ARGS = ["--stdio"]
ROOT_MARKERS = ("tsconfig.json", "package.json")
ROOT_WALK_CAP = 6


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
    bin_path = shutil.which(TS_SERVER_BIN)
    if not bin_path:
        return None
    return [bin_path] + TS_SERVER_ARGS


def enumerate(seed_terms: list[str]) -> tuple[list[dict[str, Any]], list[str]]:
    """Returns (symbols, warnings). Symbols carry {file, name, kind, line_range, query}."""
    server = find_server()
    if not server:
        # Treat missing TS server as a no-op (TS-less environment is not a failure).
        return [], []
    root = find_project_root(os.getcwd())
    if root is None:
        return [], []
    queries = [t for t in seed_terms if _is_lsp_shape(t)]
    if not queries:
        return [], []
    return query_symbols(server, root, queries)


def _is_lsp_shape(tok: str) -> bool:
    # LSP workspace/symbol works best with identifier-shaped seeds: PascalCase,
    # camelCase, or snake_case at 3+ chars. Pure-lowercase short tokens (which
    # _enumerate.extract_seeds already drops via _is_english_word_shape) would
    # match the language server's fuzzy-search and flood with noise.
    if len(tok) < 3:
        return False
    if "_" in tok:
        return True
    if any(c.isupper() for c in tok):
        return True
    return False


if __name__ == "__main__":
    import json
    import sys
    syms, warns = enumerate(sys.argv[1:])
    json.dump({"symbols": syms, "warnings": warns}, sys.stdout, indent=2)
    sys.stdout.write("\n")
