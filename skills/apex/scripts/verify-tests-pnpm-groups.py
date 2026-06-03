#!/usr/bin/env python3
"""verify-tests.sh helper: derive per-package test-file groups for pnpm workspaces.

Extracted from verify-tests.sh (414L -> 321L) to satisfy the file-health 400-line
gate (apex-improve run d58fe183). Behavior is byte-identical to the inline
heredoc it replaced - same walk depth, same runner detection, same expand
heuristic, same tab-separated output shape, with one addition: vitest 2.x
packages emit expanded test file paths (no `--related` flag, which was added
in vitest 3) so the shell layer can run `vitest run <test-files>` without
CACErroring on the unknown flag.

Invocation:
    python3 verify-tests-pnpm-groups.py "$EXISTING"
where $EXISTING is a newline-separated list of existing source file paths
(repo-relative). Cwd is the project root (caller responsibility).

Output (stdout): one line per group with TAB separators:
    {pkg_name}\t{runner}\t{pkg_rel}\t{has_test_script:0|1}\t{file1 file2 ...}
runner is one of: vitest | jest | adonis | vitest-v2 | "" (fallback).
`vitest-v2` is a synthetic runner key for pre-v3 vitest installs; the shell
layer treats it like "files-direct" (skip --related, just pass test paths).
Files in the final column are space-separated and stripped of the package-dir
prefix so they resolve relative to the runner's cwd (pnpm --filter exec runs
in that cwd).
"""
import json
import os
import sys

files = [ln for ln in sys.argv[1].splitlines() if ln.strip()]
test_suffixes = ('.test.ts', '.test.tsx', '.test.js', '.test.jsx',
                 '.spec.ts', '.spec.tsx', '.spec.js', '.spec.jsx')

# Discover workspace packages by walking up to depth 3. We deliberately ignore
# the root package.json (apps/lib monorepos rarely host runtime code there).
pkgs = []  # (rel_dir, name, runner, has_test_script)
for dirpath, dirnames, filenames in os.walk('.'):
    rel = '' if dirpath == '.' else os.path.relpath(dirpath, '.')
    if rel:
        parts = rel.split(os.sep)
        if 'node_modules' in parts or any(p.startswith('.') for p in parts):
            dirnames[:] = []
            continue
        if len(parts) > 3:
            dirnames[:] = []
            continue
    else:
        dirnames[:] = [d for d in dirnames
                      if d not in ('node_modules',) and not d.startswith('.')]
        continue
    if 'package.json' not in filenames:
        continue
    try:
        data = json.load(open(os.path.join(dirpath, 'package.json')))
    except Exception:
        continue
    name = data.get('name', '')
    if not name:
        continue
    deps = {**(data.get('dependencies') or {}),
            **(data.get('devDependencies') or {})}
    if 'vitest' in deps:
        # `--related` was added in vitest 3. Pre-v3 installs CACError on the
        # flag, so route them through the heuristic-expand path and run the
        # derived test files directly (no --related).
        import re as _re
        m = _re.search(r'(\d+)', deps['vitest'])
        major = int(m.group(1)) if m else 0
        runner = 'vitest' if major >= 3 else 'vitest-v2'
    elif 'jest' in deps:
        runner = 'jest'
    elif '@adonisjs/core' in deps:
        runner = 'adonis'
    else:
        runner = ''
    scripts = data.get('scripts') or {}
    has_test_script = 'test' in scripts
    pkgs.append((rel, name, runner, has_test_script))
    dirnames[:] = []  # do not descend into nested packages

# Group files by deepest matching package prefix.
groups = {}
for f in files:
    best = None
    best_len = -1
    for rel, name, runner, has_test in pkgs:
        prefix = rel + os.sep
        if f.startswith(prefix) and len(rel) > best_len:
            best = (rel, name, runner, has_test)
            best_len = len(rel)
    if best is None:
        continue
    groups.setdefault(best, []).append(f)


def expand(files_in_pkg, pkg_rel):
    """Expand non-test files to related test files within the package."""
    out = set()
    for f in files_in_pkg:
        if f.endswith(test_suffixes) or '/__tests__/' in f:
            if os.path.isfile(f):
                out.add(f)
            continue
        d = os.path.dirname(f) or '.'
        base = os.path.basename(f)
        stem, _, _ = base.rpartition('.')
        if not stem:
            continue
        cands = []
        for ext in ('.ts', '.tsx', '.js', '.jsx'):
            cands.append(f"{d}/{stem}.test{ext}")
            cands.append(f"{d}/{stem}.spec{ext}")
            cands.append(f"{d}/__tests__/{stem}.test{ext}")
            cands.append(f"{d}/__tests__/{stem}{ext}")
            cands.append(f"{pkg_rel}/tests/unit/{stem}.test{ext}")
            cands.append(f"{pkg_rel}/tests/unit/{stem}.spec{ext}")
            cands.append(f"{pkg_rel}/tests/{stem}.test{ext}")
            cands.append(f"{pkg_rel}/tests/{stem}.spec{ext}")
        for c in cands:
            if os.path.isfile(c):
                out.add(c)
    return sorted(out)


for (rel, name, runner, has_test), fs in groups.items():
    # jest accepts source files via --findRelatedTests (runner resolves
    # related internally). vitest v3.2.4 crashes on `run --related`, so both
    # vitest variants now go through the expand
    # path - parity with the single-package path in verify-tests.sh. adonis
    # needs explicit test files via --files. Other/empty runners use heuristic
    # expansion since we fall back to the package's `test` script.
    if runner == 'jest':
        out_files = fs
    else:
        out_files = expand(fs, rel)
    if not out_files:
        continue
    # Strip the package-dir prefix from paths so the runner receives
    # paths relative to its own cwd (pnpm --filter exec runs in that cwd).
    pkg_prefix = rel + os.sep
    rel_files = []
    for f in out_files:
        if f.startswith(pkg_prefix):
            rel_files.append(f[len(pkg_prefix):])
        else:
            rel_files.append(f)
    print(f"{name}\t{runner}\t{rel}\t{int(has_test)}\t{' '.join(rel_files)}")
