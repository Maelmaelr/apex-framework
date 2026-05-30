# apex-tech-watch: 30-day Block Rotation

Called from `SKILL.md` Step 1 (BEFORE fetching). Returns to SKILL.md for Step 2 (Fetch). Extracted from `SKILL.md` to keep the orchestrator within the file-health content budget.

Rotates blocks in `~/.claude/tmp/tech-updates.md` whose ISO-8601 header timestamp is older than 30 days into a single dated archive file under `~/.claude/tmp/tech-updates-archive/`. Idempotent: runs every fetch cycle, no-ops when nothing has aged out.

## Step 1 implementation

```
# Move blocks older than 30 days to a single dated archive file.
# Implementation: parse `## <id> - <ISO-8601>` headers; cutoff = now - 30d.
python3 - <<'PY'
import datetime, os, pathlib, re, shutil

target = pathlib.Path(os.path.expanduser("~/.claude/tmp/tech-updates.md"))
archive_dir = pathlib.Path(os.path.expanduser("~/.claude/tmp/tech-updates-archive"))
archive_dir.mkdir(parents=True, exist_ok=True)
if not target.exists() or target.stat().st_size == 0:
    raise SystemExit(0)

content = target.read_text(encoding="utf-8")
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)
# Block headers: ## <id> - <ISO-8601-Z>
header_re = re.compile(r"^## ([^\s]+) - (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\b", re.MULTILINE)
matches = list(header_re.finditer(content))
if not matches:
    raise SystemExit(0)

keep_parts, archive_parts = [], []
for i, m in enumerate(matches):
    start = m.start()
    end = matches[i + 1].start() if i + 1 < len(matches) else len(content)
    block = content[start:end]
    block_ts = datetime.datetime.fromisoformat(m.group(2).replace("Z", "+00:00"))
    (archive_parts if block_ts < cutoff else keep_parts).append(block)

if archive_parts:
    archive_file = archive_dir / f"{datetime.date.today().isoformat()}-rotation.md"
    archive_file.write_text("".join(archive_parts), encoding="utf-8")
    target.write_text("".join(keep_parts), encoding="utf-8")
    print(f"rotated {len(archive_parts)} block(s) to {archive_file}")
else:
    print("nothing to rotate")
PY
```

## Aggressive rotation (Step 3 fallback)

When SKILL.md Step 3's 256 KB hard cap is exceeded, Step 3 invokes this same rotation script with the cutoff lowered from 30 days to 7 days:

```
# the Step-1 rotation block above, re-run with cutoff = now - timedelta(days=7) (see implementation note below)
```

Implementation note: the canonical rotation block above uses a fixed 30-day cutoff. The aggressive variant changes only the `cutoff = ... timedelta(days=30)` line to `timedelta(days=7)`. Keep both variants in this file rather than parameterising at the SKILL.md call site.
