#!/usr/bin/env bash
set -euo pipefail

# Build mlx-coder Apple Silicon CLI release artifacts.
# Usage:
#   ./build-and-release.sh [arm64]
#   MLX_CODER_VERSION=0.1.0 ./build-and-release.sh arm64
#
# Version source:
#   MLX_CODER_VERSION env var, else 0.1.0
#
# Note: This script is also called as a sub-step by ./scripts/release.sh
# as part of the full release pipeline (which handles dependency updates,
# testing, and git operations before artifact creation).

ARCH="${1:-arm64}"
VERSION="${MLX_CODER_VERSION:-0.1.0}"

APP_NAME="mlx-coder"
SCHEME_NAME="MLXCoder"
CLI_NAME="mlx-coder"
RELEASE_DIR="releases"
WORK_DIR=".build/release"
BUILD_DIR_ARM64=".build/xcode-arm64"

ARTIFACT_BASE="${APP_NAME}-${VERSION}-${ARCH}"
CLI_STAGING_DIR="${WORK_DIR}/cli"
PKG_ROOT_DIR="${WORK_DIR}/pkgroot"
CLI_ARCHIVE="${RELEASE_DIR}/${ARTIFACT_BASE}.tar.gz"
PKG_FILE="${RELEASE_DIR}/${ARTIFACT_BASE}.pkg"
SHA_FILE="${RELEASE_DIR}/${ARTIFACT_BASE}.sha256"
NOTES_FILE="${RELEASE_DIR}/RELEASE_NOTES_v${VERSION}.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*" >&2
}

fail() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

require_tools() {
    log "Validating build tools"
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found"
    command -v pkgbuild >/dev/null 2>&1 || fail "pkgbuild not found"
    command -v shasum >/dev/null 2>&1 || fail "shasum not found"
    command -v tar >/dev/null 2>&1 || fail "tar not found"
    command -v pkgutil >/dev/null 2>&1 || fail "pkgutil not found"

    case "$ARCH" in
        arm64) ;;
        *) fail "Invalid architecture '$ARCH' (this project publishes Apple Silicon arm64 only)" ;;
    esac

    mkdir -p "$RELEASE_DIR" "$WORK_DIR"
    ok "Build tools are available"
}

build_arch() {
    local target_arch="$1"
    local derived_data="$2"

    log "Building ${APP_NAME} for ${target_arch}"
    rm -rf "$derived_data"
    xcodebuild \
        -scheme "$SCHEME_NAME" \
        -configuration Release \
        -destination "platform=macOS,arch=${target_arch}" \
        -derivedDataPath "$derived_data" \
        build >/dev/null

    local built_binary="${derived_data}/Build/Products/Release/${SCHEME_NAME}"
    [[ -f "$built_binary" ]] || fail "Expected binary not found: ${built_binary}"
    echo "$built_binary"
}

build_binary() {
    local output_bin="${WORK_DIR}/${CLI_NAME}"
    local arm_bin
    arm_bin="$(build_arch arm64 "$BUILD_DIR_ARM64")"
    cp "$arm_bin" "$output_bin"
    chmod +x "$output_bin"
    echo "$output_bin"
}

copy_shader_bundle() {
    # The MLX metallib must live next to the executable.
    local bundle_candidates=("${BUILD_DIR_ARM64}/Build/Products/Release/mlx-swift_Cmlx.bundle")

    local bundle_source=""
    for candidate in "${bundle_candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            bundle_source="$candidate"
            break
        fi
    done

    [[ -n "$bundle_source" ]] || fail "mlx-swift_Cmlx.bundle was not found in build output"
    echo "$bundle_source"
}

stage_cli_payload() {
    local built_binary="$1"
    local shader_bundle="$2"

    log "Staging CLI payload"
    rm -rf "$CLI_STAGING_DIR" "$PKG_ROOT_DIR"
    mkdir -p "$CLI_STAGING_DIR" "$PKG_ROOT_DIR/usr/local/bin"

    cp "$built_binary" "${CLI_STAGING_DIR}/${CLI_NAME}"
    cp -R "$shader_bundle" "${CLI_STAGING_DIR}/"

    cp "$built_binary" "${PKG_ROOT_DIR}/usr/local/bin/${CLI_NAME}"
    cp -R "$shader_bundle" "${PKG_ROOT_DIR}/usr/local/bin/"
    ok "CLI payload staged"
}

create_cli_archive() {
    log "Creating CLI tar.gz archive"
    rm -f "$CLI_ARCHIVE"
    tar -C "$CLI_STAGING_DIR" -czf "$CLI_ARCHIVE" "$CLI_NAME" mlx-swift_Cmlx.bundle
    ok "Created archive: ${CLI_ARCHIVE}"
}

create_pkg_installer() {
    log "Creating pkg installer"
    rm -f "$PKG_FILE"
    pkgbuild \
        --root "$PKG_ROOT_DIR" \
        --identifier "com.mlx-coder.cli" \
        --version "$VERSION" \
        --install-location "/" \
        "$PKG_FILE" >/dev/null
    ok "Created installer: ${PKG_FILE}"
}

generate_checksum_and_notes() {
    log "Generating checksum and release notes"
    local archive_basename pkg_basename sha_basename
    archive_basename="$(basename "$CLI_ARCHIVE")"
    pkg_basename="$(basename "$PKG_FILE")"
    sha_basename="$(basename "$SHA_FILE")"

    pushd "$RELEASE_DIR" >/dev/null
    shasum -a 256 "$archive_basename" "$pkg_basename" > "$sha_basename"
    popd >/dev/null

    cat > "$NOTES_FILE" <<EOF
# mlx-coder v${VERSION} (${ARCH})

## Artifacts

- ${archive_basename}
- ${pkg_basename}
- ${sha_basename}

## Install

1. Verify checksums:
   shasum -a 256 -c ${sha_basename}
2. Install with macOS installer:
   sudo installer -pkg ${pkg_basename} -target /
3. Verify CLI:
   /usr/local/bin/${CLI_NAME} --version

## Manual Install (No Installer)

1. Extract archive:
   tar -xzf ${archive_basename}
2. Copy files to a PATH directory (keep bundle adjacent to binary):
   sudo cp ${CLI_NAME} /usr/local/bin/${CLI_NAME}
   sudo cp -R mlx-swift_Cmlx.bundle /usr/local/bin/

## Verify

/usr/local/bin/${CLI_NAME} --version
EOF

    ok "Created checksum: ${SHA_FILE}"
    ok "Created release notes: ${NOTES_FILE}"
}

verify_artifacts() {
    log "Verifying artifacts"
    pushd "$RELEASE_DIR" >/dev/null
    shasum -a 256 -c "$(basename "$SHA_FILE")" >/dev/null
    popd >/dev/null

    tar -tzf "$CLI_ARCHIVE" | grep -q "^${CLI_NAME}$" || fail "CLI archive missing ${CLI_NAME}"
    tar -tzf "$CLI_ARCHIVE" | grep -q "^mlx-swift_Cmlx.bundle/$" || fail "CLI archive missing mlx-swift_Cmlx.bundle"

    pkgutil --payload-files "$PKG_FILE" | grep -q "^\./usr/local/bin/${CLI_NAME}$" || fail "pkg missing ${CLI_NAME} payload"
    pkgutil --payload-files "$PKG_FILE" | grep -q "^\./usr/local/bin/mlx-swift_Cmlx.bundle/default.metallib$" || fail "pkg missing MLX shader payload"

    "${CLI_STAGING_DIR}/${CLI_NAME}" --version >/dev/null
    ok "Artifact verification passed"
}

main() {
    log "Building mlx-coder CLI release"
    log "Version: ${VERSION}"
    log "Architecture: ${ARCH}"

    require_tools

    local output_binary shader_bundle
    output_binary="$(build_binary)"
    shader_bundle="$(copy_shader_bundle)"

    stage_cli_payload "$output_binary" "$shader_bundle"
    create_cli_archive
    create_pkg_installer
    generate_checksum_and_notes
    verify_artifacts

    ok "Build complete"
    echo "Archive: ${CLI_ARCHIVE}"
    echo "Installer: ${PKG_FILE}"
    echo "SHA256: ${SHA_FILE}"
    echo "Notes: ${NOTES_FILE}"
}

main "$@"
