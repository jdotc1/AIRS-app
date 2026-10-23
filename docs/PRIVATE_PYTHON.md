# Private Python runtime

The local app at `dist/private-python-ready/AIRS.app` contains a private CPython
3.15.0 runtime and the owned engine. Analysis requires no separate interpreter.
The installed system Python is untouched. See `PRIVATE_PYTHON_RESULTS.md` for
actual local evidence and remaining distribution gates.

## Source and preparation

Source: the official python.org macOS universal2 installer, release 3.15.0:
https://www.python.org/downloads/release/python-3150/

Package: `https://www.python.org/ftp/python/3.15.0/python-3.15.0-macos11.pkg`.
Pinned SHA-256:
`7c7e7eca61cbfa5f0c6f80cd594cddbfd492f4e8b3fb87e3d9fa1efebaec43ed`.
The first download was verified once; its trusted local receipt binds the package
size, inode and modification time. Preparation expands that bound installer
itself, without running the installer or copying the system installation.

From this checkout, reuse the accepted download/preparation:

```bash
python3 -I -B scripts/prepare-private-python.py --output-dir build/private-python-3.15.0 --package build/private-python-download/python-3.15.0-macos11.pkg --download-receipt build/private-python-evidence/download-receipt.json
bash scripts/package-app.sh --output-dir dist/private-python-next
open dist/private-python-next/AIRS.app
```

Choose a fresh app output directory; existing apps are protected. Packaging
reuses the prepared runtime receipt. `--python-runtime DIRECTORY` chooses another
prepared cache; `--external-python` explicitly builds the source-only developer
variant. The historical `verify-macos.sh` gate uses that developer variant.
Do not rerun unchanged gates merely to package another copy.

First preparation relocates native references into the framework and rejects
non-system dependencies outside it, including escaping relative references.
It removes Tcl/Tk, tkinter, IDLE, static archives, unused tools and bytecode caches.
It retains the launcher-required Python.app helper and headless standard library,
including native compression/crypto modules. Relocated code receives local ad-hoc
signatures for execution. This is not distribution signing or notarization.
Installer and full Python/third-party license notices accompany the framework.

The prepared runtime receipt seals initial file digests and metadata. Subsequent
reuse compares metadata without rehashing, re-signing or rerunning probes.
This is a trusted local build cache, not a tamperproof verification system.
A fresh download needs its own first-download verification and bound receipt;
do not manufacture a receipt for an unverified package.

## Native behavior and boundaries

The app marker selects `Contents/Frameworks/Python.framework/Versions/3.15/bin/python3.15`
before stale saved paths or `AIRS_PYTHON`. Missing/damaged bundled runtime or owned
engine fails closed instead of falling back to system Python or a checkout.
Settings identifies the private runtime. An external interpreter requires the
explicit development toggle (or `AIRS_USE_EXTERNAL_PYTHON=1`) and explicit path in
a packaged app. Source-only development retains known absolute-path discovery.

The existing single owned child uses explicit arguments with `-I -B -S` and an
environment stripped of PYTHON*, DYLD_* and `__PYVENV_LAUNCHER__` overrides.
Output bounds, private temporary files, cancellation, stale-result protection,
raw report preservation and the JSON boundary remain in place. No analysis
instruction, CFI or CFG semantics changed. Selected Mach-O images remain data.

AIRS does not use bundled Python for arbitrary scripts, package installation,
network services or GUI Python tools. Runtime updates require a new pinned
preparation and focused qualification. AIRS supports Apple Silicon hosts only and will not support Intel-host execution.
The underlying official runtime being universal2 does not widen that policy.

### Metadata-bound reuse after device renumbering

Reuse preserves the original runtime receipt. Exact inventory membership and
inode, size, modification time, change time and mode must still match for every
framework and notice entry. If device identifiers differ, the complete pair of
inventories must describe one common old device and one common current device;
partial, split or collapsed device mappings fail closed. Unchanged inventories
retain the existing exact-metadata behavior, including multiple devices.

An accepted renumbering is reported explicitly as metadata-bound evidence with
no fresh byte verification and no claim about the operating-system cause. The
receipt has no historical stable volume identifier, so this check cannot assert
volume identity across a remount. No hashes, signatures, dependency checks or
runtime execution are repeated, and the receipt is never rewritten by reuse.
