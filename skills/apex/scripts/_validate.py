"""Shared JSON Schema validation helper for apex artifacts.

Spec: apex-core.md "Artifact validation (JSON Schema)".

Two contracts:
  - producer_validate(data, schema_name) -- called before write; raises ValidationError
    so the caller aborts with explicit stderr (catches malformed output at source).
  - consumer_load(path, schema_name) -- called before read; on missing-file or
    invalid-content returns None (caller treats as "missing" and triggers the
    relevant gate-handling path; consumers must NEVER swallow this silently).

Best-effort: if `jsonschema` is not importable in the runtime, validation degrades
to "load JSON only" -- producer-side malformed-JSON is still caught (json.dumps
fails on non-serialisable input, json.load fails on bad bytes), but schema
violations slip through. Emits a one-line warning to stderr the first time the
fallback fires per process.

Schema directory resolution:
  1. `APEX_SCHEMA_DIR` env var if set + non-empty (consumers wanting to point at a
     sibling schema dir like skills/admin-apex/schemas/ export it before invoking).
  2. Default: skills/apex/schemas/ (relative to this file).
"""
from __future__ import annotations
import json
import os
import sys
from typing import Any, Optional


def _resolve_schema_dir() -> str:
    override = os.environ.get("APEX_SCHEMA_DIR")
    if override:
        return os.path.normpath(override)
    return os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schemas")
    )


_SCHEMA_DIR = _resolve_schema_dir()

_FALLBACK_WARNED = False

try:
    import jsonschema  # type: ignore
    from jsonschema import Draft202012Validator, RefResolver  # type: ignore
    _HAVE_JSONSCHEMA = True
except ImportError:  # pragma: no cover - environment-dependent
    _HAVE_JSONSCHEMA = False


class ValidationError(Exception):
    """Raised by producer_validate on schema or JSON violation."""


def _schema_path(name: str) -> str:
    if not name.endswith(".schema.json"):
        name = f"{name}.schema.json"
    return os.path.join(_SCHEMA_DIR, name)


def _load_schema(name: str) -> dict:
    path = _schema_path(name)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _validator(schema: dict):
    """Build a validator that resolves $ref against the schemas/ dir."""
    if not _HAVE_JSONSCHEMA:
        return None
    base_uri = f"file://{_SCHEMA_DIR}/"
    resolver = RefResolver(base_uri=base_uri, referrer=schema)
    return Draft202012Validator(schema, resolver=resolver)


def _warn_fallback() -> None:
    global _FALLBACK_WARNED
    if _FALLBACK_WARNED:
        return
    print(
        "_validate.py: jsonschema not available -- structural validation skipped "
        "(JSON-parse-only fallback)",
        file=sys.stderr,
    )
    _FALLBACK_WARNED = True


def producer_validate(data: Any, schema_name: str) -> None:
    """Validate `data` against `schema_name` before write. Raises ValidationError on fail."""
    if not _HAVE_JSONSCHEMA:
        _warn_fallback()
        try:
            json.dumps(data)
        except (TypeError, ValueError) as e:
            raise ValidationError(f"non-serialisable data for {schema_name}: {e}") from e
        return
    schema = _load_schema(schema_name)
    validator = _validator(schema)
    errors = list(validator.iter_errors(data))
    if errors:
        first = errors[0]
        raise ValidationError(
            f"{schema_name}: {first.message} (at {'/'.join(str(p) for p in first.absolute_path) or '<root>'})"
        )


def consumer_load(path: str, schema_name: str) -> Optional[Any]:
    """Load JSON from `path` and validate. Returns None if missing or invalid."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not _HAVE_JSONSCHEMA:
        _warn_fallback()
        return data
    schema = _load_schema(schema_name)
    validator = _validator(schema)
    if not validator.is_valid(data):
        return None
    return data
