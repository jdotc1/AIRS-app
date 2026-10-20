#!/bin/bash
# Compile and test on a real Apple SDK; this script never launches an inspected target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'USAGE'
Usage: AIRS_PYTHON=/absolute/path/to/python3 scripts/verify-macos.sh

On macOS 14+, verify Python 3.11+, compile and test the native package,
run the Python suite, and assemble a temporary local .app to inspect its layout.
No app or inspected binary is launched. The temporary package is removed on exit.
USAGE
    exit 0
fi
if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Unexpected argument. Use --help for usage.' >&2
    exit 2
fi
if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'Native verification requires macOS 14+ and an Apple SDK; it cannot run on Linux.' >&2
    exit 2
fi

MACOS_MAJOR="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 14 ]; then
    printf '%s\n' 'Native tests require macOS 14 or newer.' >&2
    exit 2
fi
if ! command -v swift >/dev/null 2>&1; then
    printf '%s\n' 'Swift was not found. Install Xcode or its command-line tools.' >&2
    exit 2
fi

PYTHON_EXECUTABLE="${AIRS_PYTHON:-}"
if [ -z "$PYTHON_EXECUTABLE" ]; then
    for CANDIDATE in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/3.11/bin/python3; do
        if [ -x "$CANDIDATE" ]; then PYTHON_EXECUTABLE="$CANDIDATE"; break; fi
    done
fi
case "$PYTHON_EXECUTABLE" in
    /*) ;;
    *) printf '%s\n' 'Set AIRS_PYTHON to the absolute path of a Python 3.11+ executable.' >&2; exit 2 ;;
esac
if [ ! -x "$PYTHON_EXECUTABLE" ]; then
    printf 'Python executable is unavailable: %s\n' "$PYTHON_EXECUTABLE" >&2
    exit 2
fi
"$PYTHON_EXECUTABLE" -I -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else "Python 3.11+ is required")'
export AIRS_PYTHON="$PYTHON_EXECUTABLE"

swift --version
/usr/bin/xcrun --show-sdk-path
"$PYTHON_EXECUTABLE" -I "$PROJECT_DIR/airs_cli.py" --version
swift build --package-path "$PROJECT_DIR/native" --configuration debug --product AIRSApp
swift test --package-path "$PROJECT_DIR/native" --configuration debug

# Python tests are stdlib unittest; keep their discovery rooted in this checkout.
(
    cd "$PROJECT_DIR"
    PYTHONPATH="$PROJECT_DIR/src" "$PYTHON_EXECUTABLE" -m unittest discover -s tests -v
)

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/airs-verify.XXXXXX")"
cleanup() { rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT
bash "$SCRIPT_DIR/package-app.sh" --external-python --debug --output-dir "$VERIFY_DIR/package with spaces"
APP_PATH="$VERIFY_DIR/package with spaces/AIRS.app"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
test -x "$APP_PATH/Contents/MacOS/AIRSApp"
test -x "$APP_PATH/Contents/MacOS/airs-entitlements"
"$APP_PATH/Contents/MacOS/airs-entitlements" --help
test -f "$APP_PATH/Contents/Resources/Engine/airs_cli.py"
test -f "$APP_PATH/Contents/Resources/Engine/src/airs/__init__.py"
"$PYTHON_EXECUTABLE" -I "$APP_PATH/Contents/Resources/Engine/airs_cli.py" --version
printf '%s\n' 'Automated macOS verification completed. Run the manual GUI checks in docs/NATIVE_BUILD.md before claiming runtime validation.'
