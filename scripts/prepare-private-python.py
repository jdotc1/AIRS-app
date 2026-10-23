#!/usr/bin/env python3
"""Prepare a private relocatable CPython from the pinned official macOS payload.

Never installs packages or changes system Python. A completed preparation is reused
without rehashing/re-signing/retesting unchanged runtime files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

VERSION = '3.15.0'
PACKAGE_SHA256 = '7c7e7eca61cbfa5f0c6f80cd594cddbfd492f4e8b3fb87e3d9fa1efebaec43ed'
URL = 'https://www.python.org/ftp/python/3.15.0/python-3.15.0-macos11.pkg'
PREFIX = '/Library/Frameworks/Python.framework/'
MAGIC = {bytes.fromhex(value) for value in ('cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def require(condition, message):
    if not condition: raise RuntimeError(message)


def run(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"{args[0]} failed: {error.output}") from error


def identity(path):
    stat = path.lstat()
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_mode]


def inventory(root):
    return {str(path.relative_to(root)): identity(path) for path in sorted(root.rglob('*'))}


def compare_runtime_metadata(saved, current):
    """Accept exact metadata, or one uniform device renumber across both trees.

    This preserves metadata-bound evidence only. It does not establish byte
    equality or explain why the filesystem device identifier changed.
    """
    require(set(saved) == set(current) == {'Python.framework', 'Notices'},
            'Unexpected runtime inventory groups')
    old_devices, new_devices = set(), set()
    changed_device = False
    for group in ('Python.framework', 'Notices'):
        before, after = saved[group], current[group]
        require(before and before.keys() == after.keys(),
                f'{group}: runtime inventory membership changed')
        for path, previous in before.items():
            actual = after[path]
            require(isinstance(previous, list) and isinstance(actual, list)
                    and len(previous) == len(actual) == 6
                    and all(type(value) is int for value in previous + actual),
                    f'{group}: invalid runtime metadata record')
            require(previous[1:] == actual[1:],
                    f'{group}: runtime metadata changed beyond device identity')
            old_devices.add(previous[0])
            new_devices.add(actual[0])
            changed_device |= previous[0] != actual[0]
    if not changed_device:
        return {'status': 'exact_metadata'}
    require(len(old_devices) == len(new_devices) == 1,
            'Runtime device change is not one uniform renumbering')
    return {'status': 'uniform_device_renumber',
            'previous_device': next(iter(old_devices)),
            'current_device': next(iter(new_devices))}


def reuse(root):
    receipt = json.loads((root / 'runtime-receipt.json').read_text())
    require(receipt['python_version'] == VERSION and receipt['source_sha256'] == PACKAGE_SHA256, 'Unexpected runtime receipt')
    result = compare_runtime_metadata(
        {'Python.framework': receipt['file_metadata'], 'Notices': receipt['notice_metadata']},
        {'Python.framework': inventory(root / 'Python.framework'), 'Notices': inventory(root / 'Notices')})
    if result['status'] == 'uniform_device_renumber':
        print(f"Reused metadata-bound runtime evidence with uniform device renumbering "
              f"{result['previous_device']} -> {result['current_device']}; "
              "membership, inode, size, timestamps and mode match. "
              "Original receipt unchanged; no fresh byte verification or filesystem-cause claim.")
    print('Reused private Python preparation receipt; no hashes, signing or runtime checks repeated.')


def dependencies(image):
    lines = run('/usr/bin/otool', '-L', str(image)).splitlines()
    return sorted({line.strip().split(' (compatibility')[0] for line in lines if line.startswith('\t')})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--download-receipt', type=Path)
    parser.add_argument('--reuse-only', action='store_true')
    args = parser.parse_args()
    require(sys.platform == 'darwin', 'Private macOS Python preparation requires a Mac')
    output = args.output_dir.resolve()
    if output.exists():
        reuse(output)
        return
    require(not args.reuse_only, 'Prepare the private runtime before packaging')
    require(args.package and args.download_receipt, 'Provide pinned package and first-download receipt')
    package = args.package.resolve()
    source_receipt = json.loads(args.download_receipt.read_text())
    stat = package.stat()
    require(source_receipt['sha256'] == PACKAGE_SHA256 and source_receipt['size'] == stat.st_size and source_receipt['mtime_ns'] == stat.st_mtime_ns and source_receipt['inode'] == stat.st_ino, 'Download receipt does not bind this package')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Leave an incomplete stage for diagnosis; never publish a partial runtime.
    stage = output.with_name(output.name + '.preparing')
    require(not stage.exists(), 'Incomplete preparation exists; use another output directory')
    stage.mkdir()
    expanded = stage / 'installer'
    run('/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded))
    source = expanded / 'Python_Framework.pkg/Payload'
    require((source / 'Versions/3.15/Python').is_file(), 'Expected official framework payload')
    framework = stage / 'Python.framework'
    shutil.copytree(source, framework, symlinks=True)
    notices = stage / 'Notices'
    notices.mkdir()
    shutil.copy2(expanded / 'Python_Documentation.pkg/Payload/license.html', notices / 'Python-ThirdParty-Licenses.html')
    shutil.copy2(expanded / 'Resources/License.rtf', notices / 'Installer-License.rtf')
    shutil.rmtree(expanded)
    # Development-only static archives are not loaded by Python and prevent
    # nested framework code signing. Keep runtime code, standard library/notices.
    for archive in framework.rglob('*.a'):
        if archive.is_file() and not archive.is_symlink(): archive.unlink()
    # AIRS is headless. Installer GUI/build tooling is outside this runtime.
    version = framework / 'Versions/3.15'
    for folder in [version / 'Frameworks', version / 'lib/python3.15/tkinter', version / 'lib/python3.15/idlelib']:
        if folder.exists(): shutil.rmtree(folder)
    for module in (version / 'lib/python3.15/lib-dynload').glob('_tkinter*'):
        module.unlink()
    for tool in (version / 'bin').iterdir():
        if tool.is_file() and not tool.is_symlink() and not tool.name.startswith('python3'):
            tool.unlink()
        elif tool.name.endswith('-config'): tool.unlink()
    # Drop installer-generated caches; -B prevents new bytecode at runtime.
    for cache in list(framework.rglob('__pycache__')):
        if cache.is_dir(): shutil.rmtree(cache)
    for link in [p for p in framework.rglob('*') if p.is_symlink()]:
        target = os.readlink(link)
        if target.startswith(PREFIX):
            link.unlink()
            link.symlink_to(os.path.relpath(framework / target[len(PREFIX):], link.parent))
        require(link.resolve().is_relative_to(framework.resolve()), f'Escaping runtime link: {link}')
    images = []
    for path in sorted(framework.rglob('*')):
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as file:
            if file.read(4) in MAGIC: images.append(path)
    relocations = []
    for image in images:
        options = []
        for dependency in dependencies(image):
            if dependency.startswith(PREFIX):
                destination = framework / dependency[len(PREFIX):]
                require(destination.exists(), f'Missing private dependency {dependency}')
                replacement = '@loader_path/' + os.path.relpath(destination, image.parent)
                options += ['-change', dependency, replacement]
                relocations.append([str(image.relative_to(framework)), dependency, replacement])
            elif dependency.startswith('/'):
                require(dependency.startswith(('/usr/lib/', '/System/Library/')), f'External dependency {dependency}')
            else:
                # Existing vendor-relative references must remain inside this framework.
                require(dependency.startswith(('@loader_path/', '@executable_path/')), f'Unexpected dynamic path {dependency}')
                # Executable-relative references are only accepted on the executable
                # itself; extension modules must use their loader location.
                base = image.parent
                require(not dependency.startswith('@executable_path/') or image.name in ('Python', 'python3.15'), f'Ambiguous executable-relative dependency {dependency}')
                destination = (base / dependency.split('/', 1)[1]).resolve()
                require(destination.is_relative_to(framework.resolve()) and destination.is_file(), f'Escaping/missing dynamic reference {dependency}')
        if image.suffix in ('.dylib', '.so') or image.name in ('Python', 'Tcl', 'Tk'):
            # LC_ID_DYLIB is relevant only for dylibs; otool -D identifies them.
            ids = run('/usr/bin/otool', '-D', str(image)).splitlines()
            if any(line.startswith(PREFIX) for line in ids):
                options += ['-id', '@rpath/' + str(image.relative_to(framework))]
        if options: run('/usr/bin/install_name_tool', *options, str(image))
    # Modified universal Mach-O code needs local ad-hoc signatures to execute on ARM.
    # This is preparation, not distribution signing or notarization.
    for image in sorted(images, key=lambda path: len(path.parts), reverse=True):
        run('/usr/bin/codesign', '--force', '--sign', '-', str(image))
    nested = sorted([p for p in framework.rglob('*') if not p.is_symlink() and p.is_dir() and p.suffix in ('.app', '.framework')], key=lambda path: len(path.parts), reverse=True)
    for item in nested: run('/usr/bin/codesign', '--force', '--sign', '-', str(item))
    run('/usr/bin/codesign', '--force', '--sign', '-', str(framework))
    closure = {str(image.relative_to(framework)): dependencies(image) for image in images}
    for name, values in closure.items():
        for dependency in values:
            require(not dependency.startswith(PREFIX), f'Unrelocated dependency in {name}')
            require(not dependency.startswith('/') or dependency.startswith(('/usr/lib/', '/System/Library/')), f'External dependency in {name}')
    executable = framework / 'Versions/3.15/bin/python3.15'
    environment = {key: value for key, value in os.environ.items() if not key.startswith(('PYTHON', 'DYLD_')) and key != '__PYVENV_LAUNCHER__'}
    probe = subprocess.check_output([str(executable), '-I', '-B', '-S', '-c',
        'import sys,json,hashlib,zlib,lzma,ssl,struct,ctypes; print(json.dumps({"version":sys.version,"prefix":sys.prefix,"executable":sys.executable,"isolated":sys.flags.isolated,"no_site":sys.flags.no_site,"dont_write_bytecode":sys.dont_write_bytecode,"paths":sys.path,"ssl":ssl.OPENSSL_VERSION}))'], env=environment, text=True)
    observed = json.loads(probe)
    require(observed['version'].startswith(VERSION) and Path(observed['prefix']).is_relative_to(framework), observed)
    require(all(not path.startswith('/Library/Frameworks/') for path in observed['paths']), observed)
    # First seal of this newly prepared runtime only. Copies reuse this receipt.
    digests = {}
    for path in sorted(framework.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as file: digests[str(path.relative_to(framework))] = hashlib.file_digest(file, 'sha256').hexdigest()
    receipt = {'python_version': VERSION, 'source_url': URL, 'source_sha256': PACKAGE_SHA256,
        'runtime_file_sha256': digests, 'dependency_closure': closure, 'relocations': relocations,
        'initial_probe': observed, 'omitted': ['Tcl/Tk frameworks', 'tkinter', 'IDLE', 'static archives', 'bytecode caches', 'unused bin tools'], 'scope': 'Private universal2 runtime; local ad-hoc code signatures; no distribution or clean-Mac claim'}
    # Renaming preserves inode/mtime/ctime of children; receipt records final location.
    stage.rename(output)
    receipt['file_metadata'] = inventory(output / 'Python.framework')
    receipt['notice_metadata'] = inventory(output / 'Notices')
    receipt['notice_sha256'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (output / 'Notices').iterdir()}
    (output / 'runtime-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(f'Prepared private Python {VERSION}: {output}; {len(images)} Mach-O files, {len(relocations)} relocated load references.')


if __name__ == '__main__':
    main()
