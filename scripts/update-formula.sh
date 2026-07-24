#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  update-formula.sh — Refresh the Homebrew formula for a published release
#
#  Usage:
#    ./scripts/update-formula.sh --version X.Y.Z [--push] [--tap-repo OWNER/REPO]
#
#  Options:
#    -v, --version X.Y.Z   Released version (no leading "v"). Required.
#    -p, --push            After updating, copy the formula into the tap repo
#                          and push it (requires gh auth + push rights).
#    --tap-repo OWNER/REPO GitHub tap repository. Default: derived from origin
#                          owner as <owner>/homebrew-tap.
#    -h, --help            Show this help.
#
#  What it does:
#    1. Reads the .sha256 asset from the GitHub release v<version> (falls back to
#       downloading the tarball and hashing it) to get the tarball checksum.
#    2. Rewrites packaging/homebrew/mlx-coder.rb with the new version + sha256.
#    3. With --push, clones/updates the tap repo, copies the formula to
#       Formula/mlx-coder.rb, commits, and pushes.
#
#  The release (tag v<version> with the -arm64.tar.gz + .sha256 assets) must
#  already exist on GitHub before running this — see build-and-release.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORMULA_FILE="${REPO_ROOT}/packaging/homebrew/mlx-coder.rb"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

VERSION=""
PUSH=false
TAP_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)  VERSION="$2";  shift 2 ;;
    -p|--push)     PUSH=true;      shift   ;;
    --tap-repo)    TAP_REPO="$2";  shift 2 ;;
    -h|--help)     awk '/^# ─/{f++; if(f==2) exit} f==1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$VERSION" ]] || die "Version is required. Use: $0 --version X.Y.Z"
[[ -f "$FORMULA_FILE" ]] || die "Formula not found: ${FORMULA_FILE}"
command -v gh   >/dev/null 2>&1 || die "'gh' (GitHub CLI) not found in PATH"
command -v shasum >/dev/null 2>&1 || die "'shasum' not found in PATH"

# Resolve repo slug (owner/name) from origin for release lookups + tap default.
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
REPO_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
[[ -n "$REPO_SLUG" ]] || die "Could not determine GitHub repo slug from origin remote"
OWNER="${REPO_SLUG%%/*}"
[[ -n "$TAP_REPO" ]] || TAP_REPO="${OWNER}/homebrew-tap"

TAG="v${VERSION}"
TARBALL="mlx-coder-${VERSION}-arm64.tar.gz"

log "Repo:    ${REPO_SLUG}"
log "Release: ${TAG}"
log "Tarball: ${TARBALL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Step 1: obtain the tarball sha256 ────────────────────────────────────────
SHA256=""
if gh release download "$TAG" -R "$REPO_SLUG" -p "*.sha256" -D "$TMP_DIR" --clobber >/dev/null 2>&1; then
  SHA_ASSET="$(find "$TMP_DIR" -name '*.sha256' | head -1)"
  if [[ -n "$SHA_ASSET" ]]; then
    SHA256="$(awk -v f="$TARBALL" '$2==f {print $1}' "$SHA_ASSET")"
  fi
fi

if [[ -z "$SHA256" ]]; then
  warn ".sha256 asset missing/unusable — downloading tarball to hash it directly"
  gh release download "$TAG" -R "$REPO_SLUG" -p "$TARBALL" -D "$TMP_DIR" --clobber \
    || die "Could not download ${TARBALL} from release ${TAG}"
  SHA256="$(shasum -a 256 "${TMP_DIR}/${TARBALL}" | awk '{print $1}')"
fi

[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "Computed sha256 looks invalid: '${SHA256}'"
ok "sha256: ${SHA256}"

# ── Step 2: rewrite the formula ──────────────────────────────────────────────
# BSD sed (macOS) in-place. The url, version, and sha256 lines are regenerated
# together (Homebrew requires url before version, so the version can't be
# interpolated into the url — it is written literally in both places).
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/${TARBALL}"
sed -i '' -E \
  -e "s#^([[:space:]]*url ).*#\1\"${DOWNLOAD_URL}\"#" \
  -e "s/^([[:space:]]*version )\"[^\"]*\"/\1\"${VERSION}\"/" \
  -e "s/^([[:space:]]*sha256 )\"[0-9a-f]*\"/\1\"${SHA256}\"/" \
  "$FORMULA_FILE"

# Verify the substitutions actually took.
grep -q "url \"${DOWNLOAD_URL}\"" "$FORMULA_FILE" || die "Failed to write url into formula"
grep -q "version \"${VERSION}\""  "$FORMULA_FILE" || die "Failed to write version into formula"
grep -q "sha256 \"${SHA256}\""    "$FORMULA_FILE" || die "Failed to write sha256 into formula"
ok "Updated ${FORMULA_FILE#${REPO_ROOT}/} -> ${VERSION}"

if ! $PUSH; then
  echo
  ok "Formula updated locally. Review it, then re-run with --push to publish to ${TAP_REPO}."
  exit 0
fi

# ── Step 3: publish to the tap repo ──────────────────────────────────────────
log "Publishing to tap: ${TAP_REPO}"
TAP_DIR="${TMP_DIR}/tap"
if ! gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth 1 >/dev/null 2>&1; then
  die "Could not clone ${TAP_REPO}. Create it first (public repo named 'homebrew-tap')."
fi

# A freshly created tap repo is empty (no commits, no branch). Make sure we are
# on `main` so the first push lands on GitHub's default branch.
git -C "$TAP_DIR" checkout -B main >/dev/null 2>&1 || true

mkdir -p "${TAP_DIR}/Formula"
cp "$FORMULA_FILE" "${TAP_DIR}/Formula/mlx-coder.rb"
git -C "$TAP_DIR" add Formula/mlx-coder.rb

# Use the index vs HEAD so new (untracked) files count as a change too — a plain
# `git diff` would miss the first-ever commit into an empty repo.
if git -C "$TAP_DIR" diff --cached --quiet; then
  warn "Tap formula already up to date — nothing to push."
  exit 0
fi

git -C "$TAP_DIR" commit -m "mlx-coder ${VERSION}" >/dev/null
git -C "$TAP_DIR" push -u origin main >/dev/null 2>&1 \
  || die "Push to ${TAP_REPO} failed (check push rights / branch protection)."
ok "Pushed mlx-coder ${VERSION} to ${TAP_REPO}"
echo
echo -e "${CYAN}Users can now install with:${RESET}"
echo "  brew install ${OWNER}/tap/mlx-coder"
