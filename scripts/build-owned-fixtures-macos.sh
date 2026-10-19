#!/bin/bash
# Build owned validation sources only. Never load or execute the resulting dylibs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/owned-toolchain"

usage() {
    cat <<'USAGE'
Usage: bash scripts/build-owned-fixtures-macos.sh [--output-dir DIRECTORY]

Requires macOS, Xcode/Clang and dsymutil. Builds owned ARM64 dylibs at O0 and O2,
records toolchain/UUID information, and optionally writes LLVM unwind dumps.
If AIRS_PYTHON or python3 is available at version 3.11+, writes audit JSON.
No generated library is loaded or executed. Existing outputs are not replaced.
This recipe is supplied source; actual Apple-toolchain validation must run on a Mac.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'Owned compiler-fixture builds require macOS and the Apple toolchain.' >&2
    exit 2
fi
for TOOL in clang dsymutil dwarfdump; do
    if ! /usr/bin/xcrun --find "$TOOL" >/dev/null 2>&1; then
        printf 'Required Apple tool is missing: %s\n' "$TOOL" >&2
        exit 2
    fi
done
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
for LEVEL in 0 2; do
    if [ -e "$OUTPUT_DIR/owned-O$LEVEL.dylib" ] || [ -e "$OUTPUT_DIR/owned-O$LEVEL.dylib.dSYM" ]; then
        printf '%s\n' 'Owned outputs already exist. Choose a fresh --output-dir for this run.' >&2
        exit 2
    fi
done

{
    /usr/bin/sw_vers
    /usr/bin/xcrun clang --version
    /usr/bin/xcrun --show-sdk-path
    /usr/bin/xcrun dsymutil --version
} > "$OUTPUT_DIR/toolchain.txt" 2>&1

DUMP_TOOL=""
if /usr/bin/xcrun --find llvm-objdump >/dev/null 2>&1; then
    DUMP_TOOL="$(/usr/bin/xcrun --find llvm-objdump)"
elif command -v llvm-objdump >/dev/null 2>&1; then
    DUMP_TOOL="$(command -v llvm-objdump)"
fi
PYTHON_EXECUTABLE="${AIRS_PYTHON:-}"
if [ -z "$PYTHON_EXECUTABLE" ] && command -v python3 >/dev/null 2>&1; then
    PYTHON_EXECUTABLE="$(command -v python3)"
fi
HAS_PYTHON=0
if [ -n "$PYTHON_EXECUTABLE" ] && "$PYTHON_EXECUTABLE" -I -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)' >/dev/null 2>&1; then
    HAS_PYTHON=1
fi

for LEVEL in 0 2; do
    LIBRARY="$OUTPUT_DIR/owned-O$LEVEL.dylib"
    # Retain objects so dsymutil can read their debug maps after linking.
    for SOURCE in canonical.S helpers.c; do
        /usr/bin/xcrun clang -arch arm64 -g -O"$LEVEL" \
            -mmacosx-version-min=14.0 -c "$PROJECT_DIR/fixtures/toolchain/$SOURCE" \
            -o "$OUTPUT_DIR/$SOURCE-O$LEVEL.o"
    done
    /usr/bin/xcrun clang -arch arm64 -dynamiclib -g -O"$LEVEL" \
        -mmacosx-version-min=14.0 "$OUTPUT_DIR/canonical.S-O$LEVEL.o" \
        "$OUTPUT_DIR/helpers.c-O$LEVEL.o" -o "$LIBRARY"
    /usr/bin/xcrun dsymutil "$LIBRARY" -o "$LIBRARY.dSYM"
    /usr/bin/xcrun dwarfdump --uuid "$LIBRARY" "$LIBRARY.dSYM" > "$OUTPUT_DIR/owned-O$LEVEL-identity.txt"
    if [ -n "$DUMP_TOOL" ]; then
        "$DUMP_TOOL" --macho --unwind-info "$LIBRARY" > "$OUTPUT_DIR/owned-O$LEVEL-unwind.txt"
    fi
    if [ "$HAS_PYTHON" -eq 1 ]; then
        "$PYTHON_EXECUTABLE" -I "$PROJECT_DIR/airs_cli.py" audit \
            --output "$OUTPUT_DIR/owned-O$LEVEL-audit.json" -- "$LIBRARY"
    fi
done
if [ -z "$DUMP_TOOL" ]; then
    printf '%s\n' 'llvm-objdump was not available; independent metadata dumps were not generated.'
fi
if [ "$HAS_PYTHON" -eq 0 ]; then
    printf '%s\n' 'Python 3.11+ was not available; audit JSON was not generated.'
fi
printf 'Owned fixtures compiled in: %s\n' "$OUTPUT_DIR"
printf '%s\n' 'Review the actual emitted code, compact ranges and tool versions before recording expected outcomes.'
