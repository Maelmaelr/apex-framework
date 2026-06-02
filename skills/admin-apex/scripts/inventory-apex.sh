#!/usr/bin/env bash
# Purpose: Emit canonical apex inventory JSON.
# Spec: skills/admin-apex/SKILL.md task 2 + schemas/inventory.schema.json
#
# Walks:
#   skills/apex/*.md             -> skills[] (apex sub-skills)
#   skills/apex/steps/*.md       -> skills[] (per-step lazy-load contracts; R5 budget-enforced)
#   skills/apex-*/SKILL.md       -> skills[] (sibling apex skills: improve, tech-watch,
#                                  eod, fix, init, lessons-extract, lessons-analyze,
#                                  file-health)
#   skills/admin-apex/*.md       -> skills[] (admin-apex sub-skills: SKILL, audit,
#                                  evolve, sync-docs)
#   agents/*.md                  -> agents[]
#   skills/apex/scripts/*.{sh,py,js,json}       -> scripts[]
#   skills/admin-apex/scripts/*.{sh,py,js,json} -> scripts[]
#   skills/apex-merge/scripts/*.{sh,py,js,json} -> scripts[]
#     (.js = committed Workflow scripts, *.workflow.js;
#      .json = committed data files, e.g. content-budget.json)
#   skills/apex/schemas/*.json       -> schemas[]
#   skills/admin-apex/schemas/*.json -> schemas[]
#   settings.json                -> hooks[]
#   apex-core.md, apex-core-overview.md, README.md, CLAUDE.md -> spec_docs[]
#   VERSION                      -> version
#
# Coverage rationale: the content-budget cap that audit.md applies to
# "skills/agents sub-skills" needs sibling apex-* skills + admin-apex sub-skills
# in inventory to fire (Principle 3: prevent silent bloat in framework files).
# Each entry carries words + nonws_chars (formatting-immune content size)
# alongside the historical line count; the audit detector gates docs on words.
#
# Pure read; no mutation.
#
# Args:
#   --out <path>   (required) - destination file for the inventory JSON.
#
# Exit codes:
#   0 - inventory written
#   1 - bad args / missing repo files

set -euo pipefail

OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="${2:-}"
      shift 2
      ;;
    *)
      echo "inventory-apex.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "inventory-apex.sh: --out is required" >&2
  exit 1
fi

# admin-apex/apex-improve always inventory the apex framework at ~/.claude;
# falling back to pwd would walk an unrelated project tree if invoked from
# outside the framework root. CLAUDE_PROJECT_DIR is honored only when it
# matches $HOME/.claude (defensive: nominal CC state when CC is launched from
# the framework dir).
REPO_ROOT="$HOME/.claude"
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && "$CLAUDE_PROJECT_DIR" != "$REPO_ROOT" ]]; then
  echo "inventory-apex.sh: ignoring CLAUDE_PROJECT_DIR='$CLAUDE_PROJECT_DIR' (admin-apex always operates on framework root $REPO_ROOT)" >&2
fi
cd "$REPO_ROOT"

if [[ ! -f "VERSION" ]]; then
  echo "inventory-apex.sh: VERSION file not found at $REPO_ROOT/VERSION" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

OUT="$OUT" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json
import os
import sys
import datetime
import glob

repo = os.environ["REPO_ROOT"]
out_path = os.environ["OUT"]
warnings = []


def content_metrics(path):
    """Return {lines, words, nonws_chars} for a source/prose file.

    lines keeps the historical newline-chunk count. words (whitespace-split)
    and nonws_chars (non-whitespace chars) are formatting-immune content-size
    signals: physical newline count is gamed by one-paragraph-per-line
    markdown, so the audit content-budget detector keys on words."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return {"lines": 0, "words": 0, "nonws_chars": 0}
    text = raw.decode("utf-8", "ignore")
    lines = raw.count(b"\n") + (1 if raw and not raw.endswith(b"\n") else 0)
    words = len(text.split())
    nonws_chars = sum(1 for ch in text if not ch.isspace())
    return {"lines": lines, "words": words, "nonws_chars": nonws_chars}


def collect_md(pattern):
    items = []
    for p in sorted(glob.glob(pattern)):
        if not os.path.isfile(p):
            continue
        m = content_metrics(p)
        items.append({
            "path": os.path.relpath(p, repo),
            "lines": m["lines"],
            "words": m["words"],
            "nonws_chars": m["nonws_chars"],
        })
    return items


def collect_scripts(pattern):
    items = []
    for p in sorted(glob.glob(pattern)):
        if not os.path.isfile(p):
            continue
        ext = os.path.splitext(p)[1]
        if ext == ".sh":
            kind = "sh"
        elif ext == ".py":
            kind = "py"
        elif ext == ".js":
            # Committed Workflow scripts (*.workflow.js) under a walked scripts/
            # dir. Subject to the same oversized (>500 lines) + missing-refs
            # coverage as .sh/.py so a mirrored .js cannot bloat or orphan
            # silently (workflow-adoption plan A3).
            kind = "js"
        elif ext == ".json":
            # Committed data files under a walked scripts/ dir (content-budget.json:
            # the shared per-role content-budget tier read by audit-detectors.py +
            # file-health-hook.sh). Tracked so doc / script path refs resolve (no
            # orphan-ref) and the file gets missing-refs coverage like any script.
            kind = "json"
        else:
            continue
        m = content_metrics(p)
        items.append({
            "path": os.path.relpath(p, repo),
            "lines": m["lines"],
            "words": m["words"],
            "nonws_chars": m["nonws_chars"],
            "kind": kind,
        })
    return items


def collect_schemas(pattern):
    items = []
    for p in sorted(glob.glob(pattern)):
        if not os.path.isfile(p):
            continue
        rel = os.path.relpath(p, repo)
        try:
            with open(p, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            warnings.append(f"schema unreadable: {rel}: {e}")
            continue
        items.append({
            "path": rel,
            "id": doc.get("$id", ""),
            "title": doc.get("title", ""),
        })
    return items


def collect_hooks():
    settings_path = os.path.join(repo, "settings.json")
    if not os.path.isfile(settings_path):
        warnings.append("settings.json missing")
        return []
    try:
        with open(settings_path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        warnings.append(f"settings.json unreadable: {e}")
        return []
    out = []
    hooks_root = doc.get("hooks", {}) or {}
    for event, groups in hooks_root.items():
        for grp in groups or []:
            matcher = grp.get("matcher", "")
            for h in grp.get("hooks", []) or []:
                if h.get("type") != "command":
                    continue
                out.append({
                    "event": event,
                    "matcher": matcher,
                    "command": h.get("command", ""),
                })
    return out


def collect_spec_docs():
    items = []
    for name in ("apex-core.md", "apex-core-overview.md", "README.md", "CLAUDE.md"):
        p = os.path.join(repo, name)
        if os.path.isfile(p):
            m = content_metrics(p)
            items.append({
                "path": name,
                "lines": m["lines"],
                "words": m["words"],
                "nonws_chars": m["nonws_chars"],
            })
    return items


def read_version():
    p = os.path.join(repo, "VERSION")
    with open(p, encoding="utf-8") as f:
        return f.read().strip()


inventory = {
    "skills": (
        collect_md(os.path.join(repo, "skills/apex/*.md"))
        + collect_md(os.path.join(repo, "skills/apex/steps/*.md"))
        + collect_md(os.path.join(repo, "skills/apex-*/SKILL.md"))
        + collect_md(os.path.join(repo, "skills/admin-apex/*.md"))
    ),
    "agents": collect_md(os.path.join(repo, "agents/*.md")),
    "scripts": (
        collect_scripts(os.path.join(repo, "skills/apex/scripts/*"))
        + collect_scripts(os.path.join(repo, "skills/admin-apex/scripts/*"))
        + collect_scripts(os.path.join(repo, "skills/apex-merge/scripts/*"))
    ),
    "schemas": (
        collect_schemas(os.path.join(repo, "skills/apex/schemas/*.json"))
        + collect_schemas(os.path.join(repo, "skills/admin-apex/schemas/*.json"))
    ),
    "hooks": collect_hooks(),
    "spec_docs": collect_spec_docs(),
    "version": read_version(),
    "_meta": {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "warnings": warnings,
    },
}

os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(inventory, f, indent=2)
    f.write("\n")
PY

echo "$OUT"
exit 0
