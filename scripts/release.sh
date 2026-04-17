#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  release.sh  — Dependency update + publish pipeline for mlx-coder
#
#  Usage:
#    ./scripts/release.sh [OPTIONS]
#
#  Options:
#    -v, --version VERSION   Semver tag to publish (e.g. 1.2.0).  Required (unless --build-only).
#    -m, --message MSG       Release commit message.  Optional.
#    -n, --dry-run           Print all steps but do not modify anything.
#    -k, --no-push           Tag locally but skip git pull and git push.
#    -b, --build-only        Build-only mode (incremental, quiet): skips deps, tests, and git steps.
#    -bc, --build-clean       Build-only mode (clean): nukes build caches before building (verbose).
#    -h, --help              Show this help.
#
#  What it does:
#    1. Sanity-checks the environment (git clean, on main, toolchain present).
#    2. Updates Swift Package dependencies (swift package update).
#    3. Builds a Release binary – with Metal shader pre-compilation so the
#       binary ships pre-warmed MTLLibrary caches and avoids first-run crashes.
#    4. Runs the test suite to verify correctness.
#    5. Builds distributable artifacts (.tar.gz, .pkg, .sha256 via build-and-release.sh).
#    6. Commits Package.resolved, tags, and pushes.
#
#    Note: with --build-only, step 2 still runs so Package.resolved stays fresh;
#    steps 4-6 are skipped.
#
#  Metal shader pre-compilation rationale:
#    MLX kernels are compiled as Metal shaders at first use.  Without an
#    explicit pre-warm step the very first model operation on a fresh install
#    may time-out or crash the Metal command encoder because the GPU pipeline
#    descriptor is not yet in the system shader cache.
#
#    We set METAL_DEVICE_WRAPPER_TYPE=1 during the release build so that any
#    driver warnings are surfaced at build/CI time rather than at runtime.
#    We also pass -Xswiftc -DMLX_PREWARM_SHADERS so that in-source warm-up
#    conditional compilation blocks are compiled in (see ModelLoader.swift).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ── Defaults ───────────────────────────────────────────────────────────────
VERSION=""
RELEASE_MSG=""
DRY_RUN=false
NO_PUSH=false
BUILD_ONLY=false
BUILD_CLEAN=false
DEP_CHANGES=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/releases"
CLI_ARCHIVE=""
PKG_FILE=""
SHA_FILE=""
NOTES_FILE=""

# ── Argument parsing ───────────────────────────────────────────────────────
usage() {
  # Print only the header block: lines between the two separator lines at the top.
  awk '/^# ─/{found++; if(found==2) exit} found==1{sub(/^# ?/,""); print}' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)  VERSION="$2";      shift 2 ;;
    -m|--message)  RELEASE_MSG="$2";  shift 2 ;;
    -n|--dry-run)  DRY_RUN=true;      shift   ;;
    -k|--no-push)  NO_PUSH=true;      shift   ;;
    -b|--build-only) BUILD_ONLY=true; shift   ;;
    -bc|--build-clean) BUILD_ONLY=true; BUILD_CLEAN=true; shift ;;
    -h|--help)     usage ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Dry-run wrapper ────────────────────────────────────────────────────────
run() {
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $*"
  else
    "$@"
  fi
}

patch_mlx_swift_lm_for_swift6() {
  local derived_data="$1"
  local target_file="${derived_data}/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXVLM/MediaProcessing.swift"

  if [[ ! -f "$target_file" ]]; then
    log_warn "mlx-swift-lm source not found for Swift 6 patch at: ${target_file}"
    return
  fi

  if grep -q '^private let context = CIContext()$' "$target_file"; then
    log_info "Patching mlx-swift-lm MediaProcessing.swift for Swift 6 concurrency checks"
    run sed -i '' 's/^private let context = CIContext()$/nonisolated(unsafe) private let context = CIContext()/g' "$target_file"
    log_ok "Applied Swift 6 concurrency patch to mlx-swift-lm"
    return
  fi

  if grep -q '^nonisolated(unsafe) private let context = CIContext()$' "$target_file"; then
    log_info "mlx-swift-lm Swift 6 patch already present"
    return
  fi

  log_warn "Could not find expected CIContext declaration to patch in ${target_file}"
}

# ── Validate inputs ────────────────────────────────────────────────────────
if [[ -z "$VERSION" ]]; then
  if $BUILD_ONLY; then
    BASE_VERSION=$(grep 'version: "' "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift" | grep -o 'version: "[^"]*"' | cut -d'"' -f2 | head -n 1 | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
    VERSION="${BASE_VERSION}.$(date +%Y%m%d%H%M)"
    log_info "No version specified for --build-only. Using generated version: ${VERSION}"
    TAG="v${VERSION}"
  else
    log_error "Version is required for release. Use: $0 --version X.Y.Z\nOr use --build-only to just generate the binary."
    exit 1
  fi
else
  # Validate semver (basic: digits and dots)
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?(\+[a-zA-Z0-9._-]+)?$ ]]; then
    log_warn "Version '${VERSION}' does not look like a semver (e.g. 1.2.3 or 1.2.3-beta.1)."
  fi
  TAG="v${VERSION}"
fi

[[ -z "$RELEASE_MSG" ]] && RELEASE_MSG="chore: release ${TAG}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Environment checks
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 1/5 – Environment checks"

# Must be run from the repo root (or scripts/ subdir)
cd "$REPO_ROOT"

# Check for required tools
for tool in swift git xcodebuild; do
  if ! command -v "$tool" &>/dev/null; then
    log_error "'${tool}' not found in PATH."
    exit 1
  fi
done
log_ok "Required tools present (swift, git, xcodebuild)"

# Must be on main branch (skipped with --build-only since no git operations occur)
if ! $BUILD_ONLY; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    log_error "You must be on the 'main' branch (currently on '${CURRENT_BRANCH}')."
    exit 1
  fi
  log_ok "On branch: main"
else
  log_warn "Skipping branch check (--build-only)"
fi

# Working tree must be clean (except Package.resolved which we update)
UNTRACKED=$(git status --porcelain | grep -v '^?? ' || true)
if [[ -n "$UNTRACKED" ]] && ! $DRY_RUN; then
  if $BUILD_ONLY; then
    log_warn "Working tree has uncommitted changes, but continuing due to --build-only"
  else
    log_error "Working tree has uncommitted changes:\n${UNTRACKED}"
    exit 1
  fi
else
  log_ok "Working tree clean (or dry-run)"
fi

# Tag must not already exist
if git rev-parse "$TAG" &>/dev/null; then
  log_error "Tag '${TAG}' already exists. Bump the version."
  exit 1
fi
log_ok "Tag ${TAG} is available"

# Pull latest to avoid non-fast-forward push failures (skipped with --no-push or --build-only)
if $NO_PUSH || $BUILD_ONLY; then
  log_warn "Skipping git pull (--no-push or --build-only)"
else
  log_info "Pulling latest from origin/main…"
  run git pull --ff-only origin main
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Update dependencies
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 2/5 – Update Swift Package dependencies"

if $BUILD_ONLY; then
  log_warn "Skipping dependency update in --build-only mode (fast path uses pinned dependencies from Package.resolved)"
else

# Capture the state before update
if [[ -f Package.resolved ]]; then
  cp Package.resolved Package.resolved.bak
fi

log_info "Running: swift package update"
run swift package update

# Show what changed in Package.resolved
if ! $DRY_RUN && git diff --quiet Package.resolved; then
  log_warn "Package.resolved unchanged – dependencies were already up to date."
else
  log_ok "Package.resolved updated"
  if [[ -f Package.resolved.bak ]]; then
    # Use python to compare versions cleanly
    DEP_CHANGES=$(python3 -c "
import json, sys
def get_pins(f):
    try:
        with open(f, 'r') as file:
            d = json.load(file)
            # Handle both v1 and v3 (or others)
            pins = d.get('pins', []) or d.get('object', {}).get('pins', [])
            return {p.get('identity'): p.get('state', {}).get('version', 'branch:' + str(p.get('state', {}).get('branch', '?'))) for p in pins}
    except Exception: return {}
old = get_pins('Package.resolved.bak')
new = get_pins('Package.resolved')
changes = []
for k, nv in new.items():
    ov = old.get(k)
    if ov != nv:
        if ov: changes.append(f'  {k}: {ov} -> {nv}')
        else: changes.append(f'  {k}: [NEW] {nv}')
for k, ov in old.items():
    if k not in new: changes.append(f'  {k}: [REMOVED] {ov}')
if changes: print('\n'.join(changes))
" 2>/dev/null || true)
  fi
fi

if [[ -f Package.resolved.bak ]]; then
  rm Package.resolved.bak
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Build (Release) with Metal shader pre-compilation
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 3/5 – Build release binary (with Metal shader pre-warming)"

if $BUILD_ONLY; then
  if $DRY_RUN; then
    log_info "[dry-run] Would inject version ${VERSION} into MLXCoderCLI.swift"
    log_info "[dry-run] Would run: MLX_CODER_VERSION=${VERSION} ${REPO_ROOT}/build-and-release.sh arm64"
    log_info "[dry-run] Would copy Xcode binary to .build/arm64-apple-macosx/release/mlx-coder for iterative dev runs"
    BINARY_PATH="${REPO_ROOT}/.build/release/cli/mlx-coder"
    log_info "[dry-run] Would verify binary at: ${BINARY_PATH}"
  else
    log_info "Using build-only pipeline via build-and-release.sh (matches release framework/link behavior)"
    log_info "Injecting version ${VERSION} into MLXCoderCLI.swift"
    cp "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift" "/tmp/MLXCoderCLI.swift.bak"
    trap 'mv "/tmp/MLXCoderCLI.swift.bak" "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift"' EXIT
    sed -i '' "s/version: \".*\"/version: \"${VERSION}\"/g" "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift"

    log_info "Building release artifacts to source a known-good binary"
    clean_env="0"
    $BUILD_CLEAN && clean_env="1"
    run env METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1 \
      MLX_CODER_VERSION="${VERSION}" \
      CLEAN_BUILD="${clean_env}" \
      "${REPO_ROOT}/build-and-release.sh" arm64

    BINARY_PATH="${REPO_ROOT}/.build/release/cli/mlx-coder"
    if [[ ! -f "$BINARY_PATH" ]]; then
      log_error "Expected build-only binary not found at: ${BINARY_PATH}"
      exit 1
    fi

    log_ok "Binary built: ${BINARY_PATH}"

    DEV_BIN_DIR="${REPO_ROOT}/.build/arm64-apple-macosx/release"
    DEV_BIN_PATH="${DEV_BIN_DIR}/mlx-coder"
    run mkdir -p "${DEV_BIN_DIR}"
    run cp "$BINARY_PATH" "$DEV_BIN_PATH"
    run chmod +x "$DEV_BIN_PATH"
    log_ok "Copied iterative dev binary to: ${DEV_BIN_PATH}"

    BUNDLE_SOURCE="${REPO_ROOT}/.build/release/cli/mlx-swift_Cmlx.bundle"
    METALLIB_SOURCE="${BUNDLE_SOURCE}/default.metallib"
    if [[ -f "$METALLIB_SOURCE" ]]; then
      BINARY_DIR=$(dirname "$BINARY_PATH")
      log_info "Found Metal library at: ${METALLIB_SOURCE}"
      run cp "$METALLIB_SOURCE" "${BINARY_DIR}/default.metallib"
      run cp "$METALLIB_SOURCE" "${BINARY_DIR}/mlx.metallib"
      run cp "$METALLIB_SOURCE" "${DEV_BIN_DIR}/default.metallib"
      run cp "$METALLIB_SOURCE" "${DEV_BIN_DIR}/mlx.metallib"
      if [[ -d "$BUNDLE_SOURCE" ]]; then
        run rm -rf "${BINARY_DIR}/mlx-swift_Cmlx.bundle" "${DEV_BIN_DIR}/mlx-swift_Cmlx.bundle"
        run cp -R "$BUNDLE_SOURCE" "${BINARY_DIR}/mlx-swift_Cmlx.bundle"
        run cp -R "$BUNDLE_SOURCE" "${DEV_BIN_DIR}/mlx-swift_Cmlx.bundle"
      fi
      log_ok "Colocated Metal libraries with binary (default.metallib and mlx.metallib)"
    else
      log_warn "Could not find default.metallib in Xcode Release output. MLX may fail at runtime."
    fi

    log_info "Smoke-testing binary (--help)…"
    "$BINARY_PATH" --help &>/dev/null || {
      log_error "Binary smoke test failed – check build output."
      exit 1
    }
    log_ok "Binary smoke test passed"
  fi
else

# If the repo was moved/renamed, stale clang PCH entries can keep absolute paths
# from the old location and fail with "PCH was compiled with module cache path".
MODULE_CACHE_DIR="${REPO_ROOT}/.build/arm64-apple-macosx/release/ModuleCache"
if [[ -d "$MODULE_CACHE_DIR" ]]; then
  log_info "Clearing stale module cache: ${MODULE_CACHE_DIR}"
  run rm -rf "$MODULE_CACHE_DIR"
fi

if $BUILD_ONLY && [[ -n "${BASE_VERSION:-}" ]]; then
  if ! $DRY_RUN; then
    log_info "Injecting version ${VERSION} into MLXCoderCLI.swift"
    cp "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift" "/tmp/MLXCoderCLI.swift.bak"
    # Restore file on exit so we avoid committing dirty date versions
    trap 'mv "/tmp/MLXCoderCLI.swift.bak" "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift"' EXIT
    sed -i '' "s/version: \".*\"/version: \"${VERSION}\"/g" "${REPO_ROOT}/Sources/MLXCoder/MLXCoderCLI.swift"
  else
    log_info "[dry-run] Would inject version ${VERSION} into MLXCoderCLI.swift"
  fi
fi

# METAL_DEVICE_WRAPPER_TYPE=1
#   → Enables Metal API validation layer at compile/link time so driver
#     pipeline-compile errors are caught here rather than at user runtime.
#
# MTL_SHADER_VALIDATION=1
#   → Activates Metal shader validation to catch any bad shader during
#     the pre-warm compile that the build triggers.
#
# -Xswiftc -DMLX_PREWARM_SHADERS
#   → Enables #if MLX_PREWARM_SHADERS conditional blocks in source
#     (e.g. ModelLoader.swift) that trigger a dummy MLX eval before the
#     real model load so all Metal pipelines are in the driver cache.
#
# Note: we intentionally do NOT set METAL_DEVICE_WRAPPER_TYPE in the
# shipped binary's launch environment – only in the build step.

BUILD_ENV=(
  METAL_DEVICE_WRAPPER_TYPE=1
  MTL_SHADER_VALIDATION=1
)

XCODE_DERIVED_DATA="${REPO_ROOT}/.build/xcode"
mkdir -p "${XCODE_DERIVED_DATA}"

log_info "Resolving Swift package dependencies via xcodebuild"
run xcodebuild \
  -scheme MLXCoder \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${XCODE_DERIVED_DATA}" \
  -resolvePackageDependencies \
  -quiet

if ! $DRY_RUN; then
  patch_mlx_swift_lm_for_swift6 "${XCODE_DERIVED_DATA}"
fi

log_info "Building with: ${BUILD_ENV[*]}"
run env "${BUILD_ENV[@]}" \
  xcodebuild \
    -scheme MLXCoder \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${XCODE_DERIVED_DATA}" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='MLX_PREWARM_SHADERS' \
    -quiet \
    build

if $DRY_RUN; then
  BINARY_PATH="${XCODE_DERIVED_DATA}/Build/Products/Release/MLXCoder"
  log_info "[dry-run] Would verify binary at: ${BINARY_PATH}"
  log_info "[dry-run] Would find and colocate default.metallib next to binary"
else
  BINARY_PATH="${XCODE_DERIVED_DATA}/Build/Products/Release/MLXCoder"
  if [[ ! -f "$BINARY_PATH" ]]; then
    log_error "Expected release binary not found at: ${BINARY_PATH}"
    exit 1
  fi
  log_ok "Binary built: ${BINARY_PATH}"

  # --- Metal Library Colocation ---
  # MLX requires default.metallib to be colocated with the binary or in a bundle.
  BINARY_DIR=$(dirname "$BINARY_PATH")
  BUNDLE_SOURCE="${XCODE_DERIVED_DATA}/Build/Products/Release/mlx-swift_Cmlx.bundle"
  METALLIB_SOURCE="${BUNDLE_SOURCE}/default.metallib"

  if [[ -f "$METALLIB_SOURCE" ]]; then
    log_info "Found Metal library at: ${METALLIB_SOURCE}"
    # Copy both as default.metallib and mlx.metallib
    # load_colocated_library() specifically looks for "mlx.metallib"
    run cp "$METALLIB_SOURCE" "${BINARY_DIR}/default.metallib"
    run cp "$METALLIB_SOURCE" "${BINARY_DIR}/mlx.metallib"
    if [[ -d "$BUNDLE_SOURCE" ]]; then
      run rm -rf "${BINARY_DIR}/mlx-swift_Cmlx.bundle"
      run cp -R "$BUNDLE_SOURCE" "${BINARY_DIR}/mlx-swift_Cmlx.bundle"
    fi
    log_ok "Colocated Metal libraries with binary (default.metallib and mlx.metallib)"
  else
    log_warn "Could not find default.metallib in Xcode Release output. MLX may fail at runtime."
  fi
  # --------------------------------

  # Validate that the binary links correctly and doesn't crash on --help
  log_info "Smoke-testing binary (--help)…"
  "$BINARY_PATH" --help &>/dev/null || {
    log_error "Binary smoke test failed – check build output."
    exit 1
  }
  log_ok "Binary smoke test passed"
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Run tests
# ─────────────────────────────────────────────────────────────────────────────
if $BUILD_ONLY; then
  log_step "Step 4/6 – Run test suite (SKIPPED)"
else
  log_step "Step 4/6 – Run test suite"

TEST_LOG=/tmp/mlx-coder-test.log
if $DRY_RUN; then
  run swift test --configuration release
else
  # Run swift test and capture its own exit code independently of tee.
  # (The XCTest harness re-invokes the binary with --test-bundle-path at the
  # end of the suite; ArgumentParser rejects that flag and returns exit 1,
  # which would be a false positive if we relied on pipefail through tee.)
  swift test --configuration release 2>&1 | tee "$TEST_LOG"
  TEST_EXIT=${PIPESTATUS[0]}
fi
  log_ok "All tests passed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Build distributable artifacts
# ─────────────────────────────────────────────────────────────────────────────
if $BUILD_ONLY; then
  log_step "Step 5/6 – Build distributable artifacts (SKIPPED)"
else
  log_step "Step 5/6 – Build distributable artifacts (.tar.gz, .pkg, .sha256)"

  log_info "Calling build-and-release.sh to create release artifacts…"
  
  if $DRY_RUN; then
    log_info "[dry-run] Would run: MLX_CODER_VERSION=${VERSION} ${REPO_ROOT}/build-and-release.sh arm64"
    CLI_ARCHIVE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.tar.gz"
    PKG_FILE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.pkg"
    SHA_FILE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.sha256"
    NOTES_FILE="${ARTIFACTS_DIR}/RELEASE_NOTES_v${VERSION}.md"
  else
    # Run build-and-release.sh to create distributable artifacts
    (
      cd "$REPO_ROOT"
      MLX_CODER_VERSION="$VERSION" ./build-and-release.sh arm64
    ) || {
      log_error "Failed to build release artifacts. Check build-and-release.sh output."
      exit 1
    }
    
    # Capture artifact paths
    CLI_ARCHIVE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.tar.gz"
    PKG_FILE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.pkg"
    SHA_FILE="${ARTIFACTS_DIR}/mlx-coder-${VERSION}-arm64.sha256"
    NOTES_FILE="${ARTIFACTS_DIR}/RELEASE_NOTES_v${VERSION}.md"
    
    # Verify artifacts were created
    [[ -f "$CLI_ARCHIVE" ]] || log_error "Archive not found: ${CLI_ARCHIVE}"
    [[ -f "$PKG_FILE" ]] || log_error "Installer not found: ${PKG_FILE}"
    [[ -f "$SHA_FILE" ]] || log_error "Checksum not found: ${SHA_FILE}"
  fi
  
  log_ok "Release artifacts built"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Commit, tag, and (optionally) push
# ─────────────────────────────────────────────────────────────────────────────
if $BUILD_ONLY; then
  log_step "Step 6/6 – Git operations (SKIPPED)"
else
if $NO_PUSH; then
  log_step "Step 6/6 – Commit Package.resolved and tag (local only, --no-push)"
else
  log_step "Step 6/6 – Commit Package.resolved, tag, and push"
fi

# Commit updated Package.resolved (if changed)
if ! $DRY_RUN && ! git diff --quiet Package.resolved; then
  run git add Package.resolved
  run git commit -m "${RELEASE_MSG}"
  log_ok "Committed Package.resolved"
elif $DRY_RUN; then
  run git add Package.resolved
  run git commit -m "${RELEASE_MSG}"
fi

# Create annotated tag
run git tag -a "$TAG" -m "Release ${TAG}"
log_ok "Created tag: ${TAG}"

# Push commit and tag (skipped with --no-push)
if $NO_PUSH; then
  log_warn "--no-push: skipping git push (tag ${TAG} exists locally)"
else
  run git push origin main
  run git push origin "$TAG"
  log_ok "Pushed to origin"
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✓ Released ${TAG} successfully!${RESET}"

if [[ -n "$BINARY_PATH" ]]; then
  echo -e "${CYAN}${BOLD}Binary:${RESET} ${BINARY_PATH}"
fi

if [[ -n "$CLI_ARCHIVE" ]]; then
  echo -e "${CYAN}${BOLD}Artifacts:${RESET}"
  echo "  • ${CLI_ARCHIVE}"
  echo "  • ${PKG_FILE}"
  echo "  • ${SHA_FILE}"
  echo "  • ${NOTES_FILE}"
fi

if [[ -n "$DEP_CHANGES" ]]; then
  echo -e "\n${CYAN}${BOLD}Dependency Changes:${RESET}"
  echo "$DEP_CHANGES"
fi

if $DRY_RUN; then
  echo -e "\n${YELLOW}  (dry-run: no files were actually modified)${RESET}"
fi
