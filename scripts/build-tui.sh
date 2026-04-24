#!/usr/bin/env bash
# scripts/build-tui.sh
# Build the full mlx-coder + OpenTUI stack in one shot.
#
# Steps
#   1. Build libMLXCLib.dylib with Swift Package Manager.
#   2. Copy the dylib + Swift overlay libraries to zig/libs/ for Zig to link.
#   3. Build the Zig TUI host binary.
#   4. Optionally copy everything into a self-contained bundle at dist/.
#
# Requirements
#   • macOS 15+ (Sequoia) with Xcode / Swift 6.1+
#   • Zig 0.14.0+  (https://ziglang.org/download/)
#   • Tested on Apple Silicon; x86-64 is unsupported (MLX is ARM-only)
#
# Usage
#   ./scripts/build-tui.sh [release|debug]
#
# The resulting binary is at:
#   zig/zig-out/bin/mlx-coder-tui
#
# Env vars
#   SWIFT_BUILD_FLAGS   extra flags forwarded to `swift build`
#   ZIG_BUILD_FLAGS     extra flags forwarded to `zig build`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_CONF="${1:-release}"

# Validate build config
if [[ "$BUILD_CONF" != "release" && "$BUILD_CONF" != "debug" ]]; then
    echo "Usage: $0 [release|debug]" >&2
    exit 1
fi

# Map to Swift / Zig spelling
case "$BUILD_CONF" in
    release)
        SWIFT_CONFIG="-c release"
        ZIG_OPTIMIZE="-Doptimize=ReleaseSafe"
        ;;
    debug)
        SWIFT_CONFIG="-c debug"
        ZIG_OPTIMIZE=""
        ;;
esac

SWIFT_BUILD_OUT="$REPO_ROOT/.build/$BUILD_CONF"
ZIG_LIB_DIR="$REPO_ROOT/zig/libs"

echo "==> [1/4] Building libMLXCLib.dylib (Swift, $BUILD_CONF)…"
cd "$REPO_ROOT"
# shellcheck disable=SC2086
swift build $SWIFT_CONFIG --product MLXCLib ${SWIFT_BUILD_FLAGS:-}

# Locate the dylib (SwiftPM puts it under .build/<config>/)
MLXCLIB_DYLIB="$SWIFT_BUILD_OUT/libMLXCLib.dylib"
if [[ ! -f "$MLXCLIB_DYLIB" ]]; then
    echo "ERROR: libMLXCLib.dylib not found at $MLXCLIB_DYLIB" >&2
    exit 1
fi

echo "==> [2/4] Staging dylibs for Zig linker…"
mkdir -p "$ZIG_LIB_DIR"
cp -f "$MLXCLIB_DYLIB" "$ZIG_LIB_DIR/"

# Also copy Swift runtime dylibs that libMLXCLib may reference at runtime.
# On macOS these are typically in the Xcode toolchain; we only copy them here
# if they are NOT already guaranteed to be in /usr/lib or the system dyld cache.
SWIFT_RUNTIME_LIBS=(
    "libswiftCore.dylib"
    "libswiftFoundation.dylib"
)
TOOLCHAIN_LIB_DIR="$(xcrun --show-sdk-path 2>/dev/null)/../../../Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
if [[ -d "$TOOLCHAIN_LIB_DIR" ]]; then
    for lib in "${SWIFT_RUNTIME_LIBS[@]}"; do
        if [[ -f "$TOOLCHAIN_LIB_DIR/$lib" ]]; then
            cp -f "$TOOLCHAIN_LIB_DIR/$lib" "$ZIG_LIB_DIR/" || true
        fi
    done
fi

echo "==> [3/4] Building mlx-coder-tui (Zig)…"
cd "$REPO_ROOT/zig"
# shellcheck disable=SC2086
zig build \
    "-Dlib-dir=$ZIG_LIB_DIR" \
    $ZIG_OPTIMIZE \
    ${ZIG_BUILD_FLAGS:-}

TUI_BIN="$REPO_ROOT/zig/zig-out/bin/mlx-coder-tui"
if [[ ! -f "$TUI_BIN" ]]; then
    echo "ERROR: zig build succeeded but binary not found at $TUI_BIN" >&2
    exit 1
fi

echo "==> [4/4] Creating self-contained bundle at dist/…"
DIST="$REPO_ROOT/dist"
mkdir -p "$DIST/lib"
cp -f "$TUI_BIN" "$DIST/"
cp -f "$ZIG_LIB_DIR"/*.dylib "$DIST/lib/"

# Fix the rpath in the binary so it finds the dylibs in ../lib relative to itself.
install_name_tool -add_rpath "@executable_path/../lib" "$DIST/mlx-coder-tui" 2>/dev/null || true

echo ""
echo "✓  Build complete."
echo ""
echo "   Binary:  $DIST/mlx-coder-tui"
echo "   Libs:    $DIST/lib/"
echo ""
echo "   Run with:  $DIST/mlx-coder-tui [model-path]"
echo "   Example:   $DIST/mlx-coder-tui ~/models/Qwen/Qwen3-4B-4bit"
echo ""
