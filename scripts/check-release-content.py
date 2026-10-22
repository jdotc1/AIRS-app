#!/usr/bin/env python3
"""Check newly assembled owned app content; reuse sealed runtime evidence."""
import re
import sys
from pathlib import Path


def check_source(root):
    """Inspect only the bounded Lumen payload, not its private development tree."""
    patterns = [re.compile(rb"/Users/|/home/", re.I),
                re.compile(rb"\b(?:codex|claude|chatgpt|openai|anthropic|llm)\b", re.I),
                re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
                re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{24,}"),
                re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")]
    count = 0
    for item in root.rglob('*'):
        relative = item.relative_to(root)
        if item.is_symlink() or any(part.startswith('.') for part in relative.parts):
            raise ValueError(f'Unexpected hidden file or symlink: {relative}')
        if item.is_file():
            if (relative.as_posix() != 'LICENSE'
                    and relative.parts[0] not in {'Package.swift', 'PROVENANCE.md', 'Sources'}):
                raise ValueError(f'Unexpected source payload file: {relative}')
            if any(pattern.search(item.read_bytes()) for pattern in patterns):
                raise ValueError(f'Publication marker in Lumen source: {relative}')
            count += 1
    if count < 3 or not (root / 'Package.swift').is_file():
        raise ValueError('Missing Lumen source payload')
    print(f'Lumen source content check passed: {count} files.')


def check(app):
    contents = app / 'Contents'
    if not (contents / 'Info.plist').is_file():
        raise ValueError('Expected an assembled AIRS.app')
    forbidden_names = {'.DS_Store', '.git', '.env', 'runtime-receipt.json'}
    owned = [contents / 'MacOS', contents / 'Resources' / 'Engine',
             contents / 'Resources' / 'Lumen_LumenUI.bundle',
             contents / 'Resources' / 'RuntimeNotices']
    patterns = [re.compile(rb'/Users/[^/\x00\s]+/'),
                re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),
                re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{24,}'),
                re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')]
    failures = []
    count = 0
    # Inventory only: do not rehash, execute or requalify the sealed runtime.
    for item in contents.rglob('*'):
        if item.name in forbidden_names:
            failures.append(f'Unshippable development file: {item.relative_to(app)}')
    for base in owned:
        for item in base.rglob('*'):
            if item.is_file() and not item.is_symlink():
                count += 1
                data = item.read_bytes()
                if any(pattern.search(data) for pattern in patterns):
                    # Never print matching bytes: they could be a credential.
                    failures.append(f'Private path or credential marker: {item.relative_to(app)}')
    if failures:
        raise ValueError('\n'.join(failures))
    print(f'Release content check passed: {count} owned/notice files; sealed runtime unchanged.')


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--lumen-source':
            check_source(Path(sys.argv[2]))
        else:
            check(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError) as error:
        sys.exit(str(error))
