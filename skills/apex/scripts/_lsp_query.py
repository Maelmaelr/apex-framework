#!/usr/bin/env python3
"""Step 6.a layer 3 (deterministic LSP) helper.

Spec: apex-core.md step 6.a layer 3 (LSP references).

Spawns an LSP server over stdio (typescript-language-server --stdio for the
TS path), performs the JSON-RPC handshake (initialize / initialized /
textDocument/didOpen { workspace files } / textDocument/references /
shutdown / exit), and emits one JSONL line per reference to stdout in the
shape consumed by _enumerate_merge.py:

    {"file": "<realpath>", "detail": "lsp '<term>' from <seed>", "line_range": [start, end] | null}

Workspace pre-load: the textDocument/references method only returns hits in
documents the server has been told about. Most LSP servers (incl.
typescript-language-server) require explicit didOpen per file to index it.
After didOpen on the seed file we walk the project root and didOpen every
TS/JS source file (capped at WORKSPACE_PRELOAD_CAP=200) so cross-file refs
are reachable. Pre-load is bounded to keep one-shot latency under ~10s on
typical projects.

Position resolution: finds the first occurrence of `term` in `file` via plain
text scan. If the term is not present, exit 0 with no output (not a layer error).

The agent fallback (agents/lsp-scout.md) covers non-TS languages and any case
where this deterministic path fails - hybrid integration per apex-core.md.

Args:
  --server <cmd>     LSP server command (e.g. "typescript-language-server --stdio")
  --root <path>      Project root (for rootUri + workspace pre-load)
  --file <path>      Source file containing the seed term
  --term <str>       Identifier to find references for

Exit codes: 0 = success (zero or more lines on stdout) | 1 = unrecoverable error

Per-invocation timeout: 15s wall clock (LSP server cold-start + indexing).
On timeout the server is killed and we emit nothing.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

LSP_TIMEOUT_S = 15
RECV_TIMEOUT_S = 10
WORKSPACE_PRELOAD_CAP = 200
WORKSPACE_EXCLUDES = (
    "node_modules", ".next", ".turbo", "dist", "build", "out",
    ".git", ".vscode", "coverage", "__pycache__",
)


def find_term_position(file_path: str, term: str) -> tuple[int, int] | None:
    """Return zero-indexed (line, char) of first `term` occurrence, or None."""
    try:
        with open(file_path, encoding="utf-8") as fh:
            for line_no, line in enumerate(fh):
                idx = line.find(term)
                if idx >= 0:
                    return (line_no, idx)
    except OSError:
        return None
    return None


def _send(proc: subprocess.Popen, msg: dict) -> None:
    body = json.dumps(msg).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
    proc.stdin.flush()


def _recv(proc: subprocess.Popen, deadline: float) -> dict | None:
    """Read one LSP message before deadline (monotonic seconds). None on timeout/EOF."""
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            return None
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
            # Consume header terminator + any extra headers up to the blank line.
            while True:
                sep = proc.stdout.readline()
                if sep in (b"\r\n", b"\n", b""):
                    break
            body = b""
            while len(body) < length:
                chunk = proc.stdout.read(length - len(body))
                if not chunk:
                    return None
                body += chunk
            try:
                return json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                continue
    return None


def workspace_files(project_root: str, exts: tuple[str, ...]) -> list[str]:
    """Walk project_root, return absolute paths of source files for pre-load.
    Excludes vendor / build dirs (WORKSPACE_EXCLUDES). Capped at WORKSPACE_PRELOAD_CAP."""
    out: list[str] = []
    root_abs = os.path.abspath(project_root)
    for dirpath, dirnames, filenames in os.walk(root_abs, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in WORKSPACE_EXCLUDES and not d.startswith(".")]
        for name in filenames:
            if any(name.endswith(ext) for ext in exts):
                out.append(os.path.join(dirpath, name))
                if len(out) >= WORKSPACE_PRELOAD_CAP:
                    return out
    return out


def lsp_references(server_cmd: list[str], project_root: str, file_path: str,
                   line: int, char: int, language_id: str,
                   preload_exts: tuple[str, ...] = ()) -> list[dict]:
    """Spawn LSP server, run init/didOpen/references handshake, return locations.

    preload_exts: file extensions ('.ts', '.tsx', ...) to didOpen across the
    workspace before the references query - required for cross-file refs since
    most LSP servers only index opened documents.
    """
    proc = subprocess.Popen(
        server_cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        cwd=project_root,
        bufsize=0,
    )
    deadline = time.monotonic() + LSP_TIMEOUT_S
    abs_file = os.path.abspath(file_path)
    file_uri = f"file://{abs_file}"
    root_uri = f"file://{os.path.abspath(project_root)}"

    try:
        _send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "processId": os.getpid(),
                "rootUri": root_uri,
                "workspaceFolders": [{"uri": root_uri, "name": "root"}],
                "capabilities": {"textDocument": {"references": {"dynamicRegistration": False}}},
            },
        })
        while True:
            resp = _recv(proc, deadline)
            if resp is None:
                return []
            if resp.get("id") == 1:
                break

        _send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})

        with open(file_path, encoding="utf-8") as fh:
            text = fh.read()
        _send(proc, {
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {
                "uri": file_uri, "languageId": language_id, "version": 1, "text": text,
            }},
        })

        if preload_exts:
            for path in workspace_files(project_root, preload_exts):
                if path == abs_file:
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        ptext = fh.read()
                except OSError:
                    continue
                pext = os.path.splitext(path)[1].lstrip(".").lower()
                _send(proc, {
                    "jsonrpc": "2.0", "method": "textDocument/didOpen",
                    "params": {"textDocument": {
                        "uri": f"file://{path}",
                        "languageId": _LANG_MAP.get(pext, pext or "plaintext"),
                        "version": 1,
                        "text": ptext,
                    }},
                })

        _send(proc, {
            "jsonrpc": "2.0", "id": 2, "method": "textDocument/references",
            "params": {
                "textDocument": {"uri": file_uri},
                "position": {"line": line, "character": char},
                "context": {"includeDeclaration": True},
            },
        })
        result: list[dict] = []
        while True:
            resp = _recv(proc, deadline)
            if resp is None:
                break
            if resp.get("id") == 2:
                result = resp.get("result") or []
                break

        _send(proc, {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None})
        _recv(proc, time.monotonic() + 2)
        _send(proc, {"jsonrpc": "2.0", "method": "exit", "params": None})
        return result
    finally:
        try:
            proc.stdin.close()
        except (OSError, BrokenPipeError):
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


_LANG_MAP = {
    "ts": "typescript", "tsx": "typescriptreact",
    "mts": "typescript", "cts": "typescript",
    "js": "javascript", "jsx": "javascriptreact",
    "mjs": "javascript", "cjs": "javascript",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--term", required=True)
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        return 1

    pos = find_term_position(args.file, args.term)
    if pos is None:
        return 0

    ext = os.path.splitext(args.file)[1].lstrip(".").lower()
    language_id = _LANG_MAP.get(ext, ext or "plaintext")
    server_cmd = args.server.split()
    # Pre-load extensions: TS/JS family for typescript-language-server. Other
    # servers receive an empty preload (per-server config can be added here).
    preload_exts: tuple[str, ...] = ()
    if "typescript-language-server" in args.server:
        preload_exts = (".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs")

    refs = lsp_references(server_cmd, args.root, args.file, pos[0], pos[1], language_id, preload_exts)

    for ref in refs:
        uri = ref.get("uri", "")
        if not uri.startswith("file://"):
            continue
        path = uri[len("file://"):]
        if not os.path.isfile(path):
            continue
        rng = ref.get("range") or {}
        start = (rng.get("start") or {}).get("line")
        end_line = (rng.get("end") or {}).get("line", start)
        line_range = [start + 1, end_line + 1] if isinstance(start, int) else None
        out = {
            "file": os.path.realpath(path),
            "detail": f"lsp '{args.term}' from {args.file}",
            "line_range": line_range,
        }
        print(json.dumps(out))

    return 0


if __name__ == "__main__":
    sys.exit(main())
