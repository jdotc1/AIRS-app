#!/usr/bin/env python3
"""Sign a fresh distribution copy from nested code outward."""
import argparse
import plistlib
import struct
import subprocess
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True)


def code_type(path):
    with path.open('rb') as stream:
        header = stream.read(32)
        if len(header) < 16:
            return None
        magic = header[:4]
        if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
            return struct.unpack_from('<I', header, 12)[0]
        if magic in (b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce'):
            return struct.unpack_from('>I', header, 12)[0]
        if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            wide = magic == b'\xca\xfe\xba\xbf'
            offset = struct.unpack_from('>Q' if wide else '>I', header, 16)[0]
            stream.seek(offset + 12)
            return struct.unpack('<I', stream.read(4))[0]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app.suffix != '.app':
        parser.error('Expected a fresh distribution .app copy')
    # The prepared runtime omits these tools; remove only their dangling aliases
    # in this fresh distribution copy before sealing the framework resources.
    bin_dir = app / 'Contents/Frameworks/Python.framework/Versions/3.15/bin'
    for name in ('idle3', 'pydoc3'):
        alias = bin_dir / name
        if alias.is_symlink() and not alias.exists():
            alias.unlink()
    # CPython's embedding link object is build tooling, not a runtime module.
    # Apple notarization rejects its unsigned MH_OBJECT payload in an app.
    link_object = app / 'Contents/Frameworks/Python.framework/Versions/3.15/lib/python3.15/config-3.15-darwin/python.o'
    if link_object.is_file() and not link_object.is_symlink():
        link_object.unlink()
    bundles = [app]
    bundles += [p for p in app.rglob('*') if not p.is_symlink() and p.is_dir()
                and p.suffix in ('.app', '.framework')]
    bundle_executables = set()
    for bundle in bundles:
        plist = bundle / ('Resources/Info.plist' if bundle.suffix == '.framework' else 'Contents/Info.plist')
        info = plistlib.loads(plist.read_bytes())
        executable = info['CFBundleExecutable']
        binary = bundle / executable if bundle.suffix == '.framework' else bundle / 'Contents/MacOS' / executable
        bundle_executables.add(binary.resolve())
    leaves = [p for p in app.rglob('*') if p.is_file() and not p.is_symlink()
              and p.resolve() not in bundle_executables and code_type(p) in (2, 6, 8)]
    for path in sorted(leaves):
        run('/usr/bin/codesign', '--force', '--sign', args.identity, '--timestamp', '--options', 'runtime', str(path))
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        run('/usr/bin/codesign', '--force', '--sign', args.identity, '--timestamp', '--options', 'runtime', str(bundle))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    print(f'Signed {len(leaves)} nested binaries and {len(bundles)} app/framework bundles.')


if __name__ == '__main__':
    main()
