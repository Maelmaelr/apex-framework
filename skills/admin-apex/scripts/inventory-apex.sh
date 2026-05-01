#!/usr/bin/env bash
# Purpose: Emit canonical apex inventory JSON.
# Spec: skills/admin-apex/SKILL.md task 2 + schemas/inventory.schema.json
#
# Walks:
#   skills/apex/*.md             -> skills[] (apex sub-skills)
#   skills/apex-*/SKILL.md       -> skills[] (sibling apex skills: improve, tech-watch,
#                                  eod, fix, init, lessons-extract, lessons-analyze,
#                                  file-health)
#   skills/admin-apex/*.md       -> skills[] (admin-apex sub-skills: SKILL, audit,
#                                  evolve, sync-docs)
#   agents/*.md                  -> agents[]
#   skills/apex/scripts/*.{sh,py}       -> scripts[]
#   skills/admin-apex/scripts/*.{sh,py} -> scripts[]
#   skills/apex/schemas/*.json       -> schemas[]
#   skills/admin-apex/schemas/*.json -> schemas[]
#   settings.json                -> hooks[]
#   apex-core.md, apex-core-overview.md, README.md, CLAUDE.md -> spec_docs[]
#   VERSION                      -> version
#
# Coverage rationale: the >150-line cap that audit.md applies to "skills/agents
# sub-skills" needs sibling apex-* skills + admin-apex sub-skills in inventory
# to fire (Principle 3: prevent silent bloat in framework files).
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

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
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


def line_count(path):
    try:
        with open(path, "rb") as f:
            return sum(1 for _ in f)
    except OSError:
        return 0


def collect_md(pattern):
    items = []
    for p in sorted(glob.glob(pattern)):
        if not os.path.isfile(p):
            continue
        items.append({"path": os.path.relpath(p, repo), "lines": line_count(p)})
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
        else:
            continue
        items.append({
            "path": os.path.relpath(p, repo),
            "lines": line_count(p),
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
            items.append({"path": name, "lines": line_count(p)})
    return items


def read_version():
    p = os.path.join(repo, "VERSION")
    with open(p, encoding="utf-8") as f:
        return f.read().strip()


inventory = {
    "skills": (
        collect_md(os.path.join(repo, "skills/apex/*.md"))
        + collect_md(os.path.join(repo, "skills/apex-*/SKILL.md"))
        + collect_md(os.path.join(repo, "skills/admin-apex/*.md"))
    ),
    "agents": collect_md(os.path.join(repo, "agents/*.md")),
    "scripts": (
        collect_scripts(os.path.join(repo, "skills/apex/scripts/*"))
        + collect_scripts(os.path.join(repo, "skills/admin-apex/scripts/*"))
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
