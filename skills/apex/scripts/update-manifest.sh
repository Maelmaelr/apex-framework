#!/usr/bin/env bash
# update-manifest.sh -- Update APEX session manifest JSON fields.
# Called by: apex-apex.md (2x), SKILL.md (3x)
# Usage: bash update-manifest.sh <session-id> key=value [key=value ...]
# Best-effort: exits 0 even on failure (except invalid session-id).
# Exit 0 = success (best-effort), Exit 1 = invalid session-id format.

set -euo pipefail

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  echo "Usage: bash update-manifest.sh <session-id> key=value [key=value ...]"
  echo "Updates APEX session manifest JSON fields. Best-effort (exits 0 on failure)."
  exit 0
fi

if [[ ! "${1:-}" =~ ^apex-[a-z0-9]{8}$ ]]; then
  echo "error: invalid session-id format (expected: apex-XXXXXXXX)" >&2
  exit 1
fi

session_id="$1"
shift

python3 -c "
import json,sys
f='.claude-tmp/apex-active/'+sys.argv[1]+'.json'
with open(f, encoding='utf-8') as fh:
    d=json.load(fh)
for arg in sys.argv[2:]:
    k,v=arg.split('=',1)
    if v=='true': v=True
    elif v=='false': v=False
    elif v=='null': v=None
    else:
        try: v=int(v)
        except ValueError: pass
    d[k]=v
with open(f,'w', encoding='utf-8') as fh:
    json.dump(d,fh)
" "$session_id" "$@" 2>/dev/null; true
