#!/usr/bin/env python3
"""Exercise one relocated version-2 plan using an explicit owned differing pair.

Copies the fixture apps as data. Only airs-entitlements is executed. The evidence
folder must be new; existing verification and source artifacts remain untouched.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('cli', 'previous', 'current', 'evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), required=True)
    args = parser.parse_args()
    cli, previous, current, root = (p.absolute() for p in (args.cli, args.previous, args.current, args.evidence))
    root.mkdir(parents=True, exist_ok=False)
    original = root / 'original'
    original.mkdir()
    shutil.copytree(previous, original / 'Previous.app', symlinks=True)
    shutil.copytree(current, original / 'Current.app', symlinks=True)
    plan = {'kind': 'airs-entitlement-batch-manifest', 'version': 2, 'pairs': [
        {'previousPath': 'Previous.app', 'currentPath': 'Current.app', 'architecture': args.architecture}]}
    (original / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n', encoding='utf-8')
    moved = root / 'moved'
    original.rename(moved)
    output = root / 'reports'
    process = subprocess.run([str(cli), 'batch', '--manifest', str(moved / 'plan.json'),
                              '--output-directory', str(output)], cwd=root,
                             capture_output=True, timeout=30, check=False)
    (root / 'run.stdout').write_bytes(process.stdout)
    (root / 'run.stderr').write_bytes(process.stderr)
    if process.returncode != 1 or process.stderr:
        raise RuntimeError(f'Expected differing pair exit 1 without diagnostics; got {process.returncode}')
    result = json.loads(process.stdout)
    rows = result['rows']
    if len(rows) != 1 or rows[0]['status'] != 'completed' or rows[0]['architecture'] != args.architecture:
        raise RuntimeError('Relative plan did not complete with selected architecture')
    if (output / 'summary.json').read_bytes() != process.stdout:
        raise RuntimeError('Saved summary differs from stdout')
    report = json.loads((output / rows[0]['reportFile']).read_bytes())
    if report['schemaVersion'] != 1 or report['tool'] != 'EntitlementDiff':
        raise RuntimeError('Pair report compatibility changed')
    print('PASS: moved relative plan, independent working directory, one completed comparison, exit 1.')
    print('Only the native CLI was executed; fixture apps remained input data.')


if __name__ == '__main__':
    main()
