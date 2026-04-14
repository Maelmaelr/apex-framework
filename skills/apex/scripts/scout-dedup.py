#!/usr/bin/env python3
"""Scout finding deduplication and convergence detection.

Reads scout findings with FINGERPRINT fields, deduplicates against a persistent
store keyed by theme, and reports delta + convergence metrics.

Persistent store: .claude/scout-findings/{theme}.json
Format mirrors audit-verdicts pattern (file-hash-based staleness detection).

Usage:
    python3 scout-dedup.py --theme exploration --findings-file findings.md
    cat findings.md | python3 scout-dedup.py --theme audit
    python3 scout-dedup.py --theme exploration --findings-file findings.md --no-persist

Exit codes:
    0 = new findings exist (not converged)
    1 = converged (no new findings, <10% new ratio)
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def parse_findings(text):
    """Extract findings with FINGERPRINT fields from scout output.

    Handles both exploration format (- FINGERPRINT: ...) and audit format
    (FINGERPRINT: ... inside --- blocks). Returns list of dicts with keys:
    fingerprint, file_path, raw_text (the full finding block).
    """
    findings = []

    # Split into finding blocks -- exploration uses blank-line separation,
    # audit uses --- delimiters
    blocks = re.split(r'\n(?=- TYPE:|\n---\n)', text)

    for block in blocks:
        fp_match = re.search(r'[-\s]*FINGERPRINT:\s*(.+)', block)
        if not fp_match:
            continue

        fingerprint = fp_match.group(1).strip()

        # Extract file path -- exploration: FILE field, audit: TARGET field
        file_match = re.search(r'[-\s]*(?:FILE|TARGET):\s*(\S+)', block)
        file_path = None
        if file_match:
            raw = file_match.group(1).strip()
            # Strip line number suffix (path:line -> path)
            file_path = re.sub(r':\d+$', '', raw)

        findings.append({
            'fingerprint': fingerprint,
            'file_path': file_path,
            'raw_text': block.strip(),
        })

    return findings


def git_hash_object(file_path):
    """Get git hash for a file. Returns None if file not tracked or missing."""
    try:
        result = subprocess.run(
            ['git', 'hash-object', file_path],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def load_store(store_path):
    """Load persistent finding store. Returns dict or empty dict."""
    if store_path.exists():
        try:
            with open(store_path, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {'findings': {}, 'version': 1}


def save_store(store_path, store):
    """Write persistent finding store."""
    store_path.parent.mkdir(parents=True, exist_ok=True)
    with open(store_path, 'w') as f:
        json.dump(store, f, indent=2, sort_keys=True)


def dedup(new_findings, store):
    """Deduplicate new findings against persistent store.

    Returns (delta, updated_store) where delta is a dict:
        new: list of genuinely new findings
        carried: list of findings carried forward (unchanged)
        invalidated: list of findings where file changed (re-reported)
    """
    stored = store.get('findings', {})
    delta = {'new': [], 'carried': [], 'invalidated': []}
    updated = {}

    for finding in new_findings:
        fp = finding['fingerprint']
        file_path = finding['file_path']
        current_hash = git_hash_object(file_path) if file_path else None

        if fp in stored:
            prev = stored[fp]
            prev_hash = prev.get('file_hash')

            if current_hash and prev_hash and current_hash == prev_hash:
                # Same fingerprint, same file content -- carried forward
                delta['carried'].append(finding)
                updated[fp] = prev  # keep original entry
            else:
                # Same fingerprint but file changed -- invalidated, re-report
                delta['invalidated'].append(finding)
                updated[fp] = {
                    'file_path': file_path,
                    'file_hash': current_hash,
                    'raw_text': finding['raw_text'],
                }
        else:
            # New fingerprint
            delta['new'].append(finding)
            updated[fp] = {
                'file_path': file_path,
                'file_hash': current_hash,
                'raw_text': finding['raw_text'],
            }

    # Preserve stored findings not in current run (they may still be valid)
    for fp, entry in stored.items():
        if fp not in updated:
            # Check if file still has same hash -- if so, finding persists
            prev_hash = entry.get('file_hash')
            prev_path = entry.get('file_path')
            if prev_path:
                current_hash = git_hash_object(prev_path)
                if current_hash and prev_hash and current_hash == prev_hash:
                    updated[fp] = entry

    return delta, {'findings': updated, 'version': 1}


def format_delta_report(delta, total_stored):
    """Format human-readable delta report with convergence signal."""
    n_new = len(delta['new'])
    n_carried = len(delta['carried'])
    n_invalidated = len(delta['invalidated'])
    total = n_new + n_carried + n_invalidated + total_stored

    lines = []
    lines.append(
        f'DELTA: {n_new} new, {n_carried} carried forward, '
        f'{n_invalidated} invalidated'
    )

    if total > 0:
        pct = (n_new / total) * 100
        converged = pct < 10 and n_new == 0
        lines.append(
            f'CONVERGENCE: {"yes" if converged else "no"} '
            f'({n_new}/{total} = {pct:.0f}% '
            f'{"<" if pct < 10 else ">="} 10% threshold)'
        )
    else:
        lines.append('CONVERGENCE: yes (0 findings total)')

    if n_new > 0:
        lines.append('')
        lines.append('New findings:')
        for f in delta['new']:
            lines.append(f'  - {f["fingerprint"]}')

    if n_invalidated > 0:
        lines.append('')
        lines.append('Invalidated (file changed):')
        for f in delta['invalidated']:
            lines.append(f'  - {f["fingerprint"]}')

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(
        description='Scout finding deduplication and convergence detection'
    )
    parser.add_argument(
        '--theme', required=True,
        help='Finding theme (used as persistent store key)'
    )
    parser.add_argument(
        '--findings-file',
        help='Path to scout findings file (default: stdin)'
    )
    parser.add_argument(
        '--store-dir', default='.claude/scout-findings',
        help='Persistent store directory (default: .claude/scout-findings/)'
    )
    parser.add_argument(
        '--no-persist', action='store_true',
        help='Skip writing updated store to disk'
    )

    args = parser.parse_args()

    # Read findings
    if args.findings_file:
        with open(args.findings_file, 'r') as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    new_findings = parse_findings(text)
    if not new_findings:
        print('DELTA: 0 new, 0 carried forward, 0 invalidated')
        print('CONVERGENCE: yes (no findings parsed from input)')
        sys.exit(1)

    # Load and dedup
    store_path = Path(args.store_dir) / f'{args.theme}.json'
    store = load_store(store_path)

    # Count findings only in store (not in current run) for total calc
    stored_only = len([
        fp for fp in store.get('findings', {})
        if fp not in {f['fingerprint'] for f in new_findings}
    ])

    delta, updated_store = dedup(new_findings, store)

    # Persist
    if not args.no_persist:
        save_store(store_path, updated_store)

    # Report
    report = format_delta_report(delta, stored_only)
    print(report)

    # Exit code: 0 = new findings exist, 1 = converged
    n_new = len(delta['new'])
    n_invalidated = len(delta['invalidated'])
    if n_new == 0 and n_invalidated == 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
