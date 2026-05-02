#!/usr/bin/env python3
"""Minimal LSP JSON-RPC stdio client for scout 6.a layer_lsp.

Spec: apex-core.md step 6.a. Used by _lsp_typescript.py and _lsp_python.py to
query workspace/symbol against a language server. Silent-absorb failure
contract per skills/apex/SKILL.md and the deferred-finding scout-6a-lsp-layer
design (admin-apex run e199ee86): catch all subprocess / timeout / protocol
errors, return ([], [warning_str]) so the caller emits zero findings for that
language and propagates the warning into findings.json `_meta.warnings`.

Public API:
  query_symbols(server_cmd, project_root, queries, timeout_s=10.0)
    -> (symbols: list[dict], warnings: list[str])

Each symbol dict carries: {file, name, kind, line_range}.
"""
from __future__ import annotations
import json
import os
import shutil
import subprocess
import threading
import time
from typing import Any
from urllib.parse import unquote, urlparse

INIT_TIMEOUT_S = 10.0
QUERY_TIMEOUT_S = 5.0
SHUTDOWN_TIMEOUT_S = 2.0
MAX_SYMBOLS_PER_QUERY = 50


def _encode(msg: dict) -> bytes:
    body = json.dumps(msg).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


def _read_message(stream, deadline: float) -> dict | None:
    # Read headers up to \r\n\r\n.
    header = b""
    while b"\r\n\r\n" not in header:
        if time.monotonic() > deadline:
            return None
        chunk = stream.read(1)
        if not chunk:
            return None
        header += chunk
    raw = header.split(b"\r\n\r\n", 1)[0].decode("ascii", errors="replace")
    length = 0
    for line in raw.split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length <= 0:
        return None
    body = b""
    while len(body) < length:
        if time.monotonic() > deadline:
            return None
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    try:
        return json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None


def _drain_stderr(proc: subprocess.Popen) -> None:
    # Background drain so the server does not block on a full stderr pipe.
    try:
        for _ in iter(lambda: proc.stderr.read(4096), b""):
            pass
    except Exception:
        pass


def query_symbols(
    server_cmd: list[str],
    project_root: str,
    queries: list[str],
    timeout_s: float = QUERY_TIMEOUT_S,
) -> tuple[list[dict[str, Any]], list[str]]:
    if not server_cmd or not shutil.which(server_cmd[0]):
        return [], [f"lsp:{server_cmd[0] if server_cmd else '?'}:binary-missing"]
    if not os.path.isdir(project_root):
        return [], [f"lsp:{server_cmd[0]}:no-project-root"]

    try:
        proc = subprocess.Popen(
            server_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=project_root,
        )
    except (OSError, ValueError):
        return [], [f"lsp:{server_cmd[0]}:spawn-failed"]

    threading.Thread(target=_drain_stderr, args=(proc,), daemon=True).start()

    rid = 0
    warnings: list[str] = []

    def send(method: str, params: dict, notify: bool = False) -> int | None:
        nonlocal rid
        msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            rid += 1
            msg["id"] = rid
        try:
            proc.stdin.write(_encode(msg))
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        return msg.get("id")

    def recv_response(target_id: int, deadline: float) -> dict | None:
        # Drain messages until we see the matching id or deadline.
        while time.monotonic() < deadline:
            msg = _read_message(proc.stdout, deadline)
            if msg is None:
                return None
            if msg.get("id") == target_id:
                return msg
        return None

    try:
        init_id = send("initialize", {
            "processId": os.getpid(),
            "rootUri": f"file://{project_root}",
            "capabilities": {"workspace": {"symbol": {}}},
        })
        if init_id is None:
            warnings.append(f"lsp:{server_cmd[0]}:init-write-failed")
            return [], warnings
        resp = recv_response(init_id, time.monotonic() + INIT_TIMEOUT_S)
        if resp is None or "error" in resp:
            warnings.append(f"lsp:{server_cmd[0]}:init-timeout-or-error")
            return [], warnings
        send("initialized", {}, notify=True)

        symbols: list[dict[str, Any]] = []
        for q in queries:
            qid = send("workspace/symbol", {"query": q})
            if qid is None:
                warnings.append(f"lsp:{server_cmd[0]}:write-failed:{q}")
                continue
            r = recv_response(qid, time.monotonic() + timeout_s)
            if r is None:
                warnings.append(f"lsp:{server_cmd[0]}:query-timeout:{q}")
                continue
            result = r.get("result") or []
            if not isinstance(result, list):
                continue
            for item in result[:MAX_SYMBOLS_PER_QUERY]:
                loc = item.get("location") or {}
                uri = loc.get("uri") or ""
                if not uri.startswith("file://"):
                    continue
                path = unquote(urlparse(uri).path)
                if not path or not os.path.isfile(path):
                    continue
                rng = loc.get("range") or {}
                start = (rng.get("start") or {}).get("line")
                end = (rng.get("end") or {}).get("line", start)
                line_range = (
                    [start + 1, end + 1]
                    if isinstance(start, int) and isinstance(end, int) else None
                )
                symbols.append({
                    "file": path,
                    "name": item.get("name", ""),
                    "kind": item.get("kind", 0),
                    "line_range": line_range,
                    "query": q,
                })
        return symbols, warnings
    finally:
        try:
            send("shutdown", {})
            send("exit", {}, notify=True)
            try:
                proc.wait(timeout=SHUTDOWN_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                proc.kill()
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 4:
        print("usage: _lsp_client.py <server-binary> <project-root> <query> [<query>...]", file=sys.stderr)
        sys.exit(2)
    syms, warns = query_symbols([sys.argv[1]], sys.argv[2], sys.argv[3:])
    json.dump({"symbols": syms, "warnings": warns}, sys.stdout, indent=2)
    sys.stdout.write("\n")
