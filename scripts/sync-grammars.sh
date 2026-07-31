#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  sync-grammars.sh — Vendored tree-sitter runtime + tier-1 grammar sync
#  (plan docs/CODEGRAPH-PLAN.md §13.2)
#
#  Usage:
#    scripts/sync-grammars.sh            Fetch pinned sources over HTTPS,
#                                         verify/record sha256, (re)write
#                                         grammars/manifest.json, vendor the
#                                         files under Sources/CTreeSitter*/.
#    scripts/sync-grammars.sh --check    Offline, no network: re-hash every
#                                         file already vendored on disk and
#                                         compare against grammars/manifest.json.
#                                         Fails (exit 1) on any drift — this is
#                                         the fast mode wired into
#                                         scripts/release.sh.
#
#  This script is deliberately "deliberate update" only (plan §13.2): it never
#  auto-fetches newer upstream at build/CI time. `--check` does zero network
#  I/O. Bumping a pin means editing the tables below and re-running the
#  fetch mode by hand.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/grammars/manifest.json"
CHECK_MODE=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log_info()  { echo -e "${CYAN}[sync-grammars]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[sync-grammars]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[sync-grammars]${RESET} $*"; }
log_error() { echo -e "${RED}[sync-grammars]${RESET} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_MODE=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Pin table ──────────────────────────────────────────────────────────────
# Runtime (tree-sitter/tree-sitter). ABI: TREE_SITTER_LANGUAGE_VERSION=15,
# TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION=13 at this commit.
RUNTIME_REPO="tree-sitter/tree-sitter"
RUNTIME_COMMIT="64402de2857cc197ecc4ca3bc144ea91fda7e72e"
RUNTIME_DEST="Sources/CTreeSitter"
RUNTIME_ABI_MAX=15
RUNTIME_ABI_MIN=13

# lib/src top-level files (compiled in as a single translation unit via
# lib.c's `#include "./x.c"` amalgamation — see Package.swift `sources:
# ["lib.c"]`; the rest sit on disk only to satisfy those relative includes).
RUNTIME_LIB_SRC_FILES=(
  alloc.c alloc.h array.h atomic.h error_costs.h
  get_changed_ranges.c get_changed_ranges.h host.h
  language.c language.h length.h lexer.c lexer.h lib.c node.c
  parser.c parser.h point.c point.h query.c reduce_action.h reusable_node.h
  stack.c stack.h subtree.c subtree.h tree.c tree.h
  tree_cursor.c tree_cursor.h ts_assert.h unicode.h
  wasm_store.c wasm_store.h
)
RUNTIME_PORTABLE_FILES=(endian.h)
RUNTIME_UNICODE_FILES=(ptypes.h umachine.h urename.h utf.h utf16.h utf8.h)
# lib/include/tree_sitter/api.h is fetched separately (public header).

# Tier-1 grammars: name | repo | pinned commit | src subdir within repo |
# dest dir | has external scanner (0/1) | exported TSLanguage function |
# ABI (LANGUAGE_VERSION) recorded at that commit, for the manifest.
GRAMMAR_NAMES=(swift csharp javascript typescript)

grammar_field() {
  local name="$1" field="$2"
  case "${name}:${field}" in
    swift:repo)       echo "alex-pinkus/tree-sitter-swift" ;;
    swift:commit)     echo "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5" ;;
    swift:srcdir)     echo "src" ;;
    swift:dest)       echo "Sources/CTreeSitterSwift" ;;
    swift:scanner)    echo "1" ;;
    swift:symbol)     echo "tree_sitter_swift" ;;
    swift:abi)        echo "14" ;;
    csharp:repo)      echo "tree-sitter/tree-sitter-c-sharp" ;;
    csharp:commit)    echo "cac6d5fb595f5811a076336682d5d595ac1c9e85" ;;
    csharp:srcdir)    echo "src" ;;
    csharp:dest)      echo "Sources/CTreeSitterCSharp" ;;
    csharp:scanner)   echo "1" ;;
    csharp:symbol)    echo "tree_sitter_c_sharp" ;;
    csharp:abi)       echo "15" ;;
    javascript:repo)    echo "tree-sitter/tree-sitter-javascript" ;;
    javascript:commit)  echo "44c892e0be055ac465d5eeddae6d3e194424e7de" ;;
    javascript:srcdir)  echo "src" ;;
    javascript:dest)    echo "Sources/CTreeSitterJavaScript" ;;
    javascript:scanner) echo "1" ;;
    javascript:symbol)  echo "tree_sitter_javascript" ;;
    javascript:abi)     echo "15" ;;
    typescript:repo)    echo "tree-sitter/tree-sitter-typescript" ;;
    typescript:commit)  echo "f975a621f4e7f532fe322e13c4f79495e0a7b2e7" ;;
    typescript:srcdir)  echo "typescript/src" ;;
    typescript:dest)    echo "Sources/CTreeSitterTypeScript" ;;
    typescript:scanner) echo "1" ;;
    typescript:symbol)  echo "tree_sitter_typescript" ;;
    typescript:abi)     echo "14" ;;
    # tree-sitter-typescript's scanner.c is `#include "../../common/scanner.h"`
    # (shared between the typescript/ and tsx/ sub-grammars in that monorepo) —
    # vendor the shared header too, at the repo-relative path that makes the
    # relative include resolve (see `run_fetch`'s mirrored `<srcdir>/` layout).
    typescript:commonfile) echo "common/scanner.h" ;;
    *:commonfile) echo "" ;;
    *) log_error "unknown grammar field ${name}:${field}"; exit 1 ;;
  esac
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# ── --check mode: offline, hash what's on disk against the manifest ────────
run_check() {
  if [[ ! -f "$MANIFEST" ]]; then
    log_error "No manifest at ${MANIFEST}. Run scripts/sync-grammars.sh (without --check) first."
    exit 1
  fi
  if ! command -v python3 &>/dev/null; then
    log_error "python3 required for manifest parsing."
    exit 1
  fi

  local drift=0
  # Manifest is {"files": {"<repo-relative path>": "<sha256>", ...}, ...}
  while IFS=$'\t' read -r relpath expected; do
    [[ -z "$relpath" ]] && continue
    local abspath="${REPO_ROOT}/${relpath}"
    if [[ ! -f "$abspath" ]]; then
      log_error "MISSING vendored file: ${relpath}"
      drift=1
      continue
    fi
    local actual
    actual="$(sha256_of "$abspath")"
    if [[ "$actual" != "$expected" ]]; then
      log_error "HASH DRIFT: ${relpath} (expected ${expected}, got ${actual})"
      drift=1
    fi
  done < <(python3 -c "
import json
with open('${MANIFEST}') as f:
    m = json.load(f)
for path, sha in m.get('files', {}).items():
    print(f'{path}\t{sha}')
")

  if [[ "$drift" -ne 0 ]]; then
    log_error "Grammar manifest check FAILED — vendored files don't match grammars/manifest.json."
    exit 1
  fi
  log_ok "All $(python3 -c "import json;print(len(json.load(open('${MANIFEST}'))['files']))") vendored files match the manifest. No drift."
}

# ── fetch mode: pull pinned commits over HTTPS, verify, vendor, write manifest
RAW_BASE="https://raw.githubusercontent.com"

fetch_file() {
  # fetch_file <repo> <commit> <repo-path> <dest-abs-path>
  local repo="$1" commit="$2" repopath="$3" dest="$4"
  mkdir -p "$(dirname "$dest")"
  local url="${RAW_BASE}/${repo}/${commit}/${repopath}"
  if ! curl -sf --max-time 60 -o "$dest" "$url"; then
    log_error "Failed to fetch ${url}"
    exit 1
  fi
}

declare -a MANIFEST_ENTRIES=()

record_file() {
  # record_file <dest-abs-path>  (path must be under REPO_ROOT)
  local dest="$1"
  local rel="${dest#${REPO_ROOT}/}"
  local sha
  sha="$(sha256_of "$dest")"
  # A REAL tab (not the two literal characters `\t`) — `write_manifest`
  # splits on this with `IFS=$'\t' read`; got this wrong once already
  # (literal backslash-t only "worked" by accident of JSON's `\t` escape
  # decoding back to a real tab at parse time — fixed to be correct by
  # construction instead of correct by coincidence).
  MANIFEST_ENTRIES+=("${rel}$(printf '\t')${sha}")
}

run_fetch() {
  log_info "Fetching tree-sitter runtime @ ${RUNTIME_COMMIT} (${RUNTIME_REPO})"
  for f in "${RUNTIME_LIB_SRC_FILES[@]}"; do
    dest="${REPO_ROOT}/${RUNTIME_DEST}/${f}"
    fetch_file "$RUNTIME_REPO" "$RUNTIME_COMMIT" "lib/src/${f}" "$dest"
    record_file "$dest"
  done
  for f in "${RUNTIME_PORTABLE_FILES[@]}"; do
    dest="${REPO_ROOT}/${RUNTIME_DEST}/portable/${f}"
    fetch_file "$RUNTIME_REPO" "$RUNTIME_COMMIT" "lib/src/portable/${f}" "$dest"
    record_file "$dest"
  done
  for f in "${RUNTIME_UNICODE_FILES[@]}"; do
    dest="${REPO_ROOT}/${RUNTIME_DEST}/unicode/${f}"
    fetch_file "$RUNTIME_REPO" "$RUNTIME_COMMIT" "lib/src/unicode/${f}" "$dest"
    record_file "$dest"
  done
  dest="${REPO_ROOT}/${RUNTIME_DEST}/include/tree_sitter/api.h"
  fetch_file "$RUNTIME_REPO" "$RUNTIME_COMMIT" "lib/include/tree_sitter/api.h" "$dest"
  record_file "$dest"
  log_ok "Runtime vendored under ${RUNTIME_DEST}/"

  for name in "${GRAMMAR_NAMES[@]}"; do
    local repo commit srcdir dest_dir has_scanner commonfile
    repo="$(grammar_field "$name" repo)"
    commit="$(grammar_field "$name" commit)"
    srcdir="$(grammar_field "$name" srcdir)"
    dest_dir="$(grammar_field "$name" dest)"
    has_scanner="$(grammar_field "$name" scanner)"
    commonfile="$(grammar_field "$name" commonfile)"

    log_info "Fetching grammar '${name}' @ ${commit} (${repo})"
    # Mirror the exact repo-relative `<srcdir>/` depth on disk (not flattened)
    # so any `#include "../../something.h"` inside scanner.c — as used by
    # tree-sitter-typescript to share a scanner with its tsx/ sibling —
    # resolves the same way it does upstream.
    dest="${REPO_ROOT}/${dest_dir}/${srcdir}/parser.c"
    fetch_file "$repo" "$commit" "${srcdir}/parser.c" "$dest"
    record_file "$dest"

    if [[ "$has_scanner" == "1" ]]; then
      dest="${REPO_ROOT}/${dest_dir}/${srcdir}/scanner.c"
      fetch_file "$repo" "$commit" "${srcdir}/scanner.c" "$dest"
      record_file "$dest"
    fi

    for hdr in alloc.h array.h parser.h; do
      dest="${REPO_ROOT}/${dest_dir}/${srcdir}/tree_sitter/${hdr}"
      fetch_file "$repo" "$commit" "${srcdir}/tree_sitter/${hdr}" "$dest"
      record_file "$dest"
    done

    if [[ -n "$commonfile" ]]; then
      dest="${REPO_ROOT}/${dest_dir}/${commonfile}"
      fetch_file "$repo" "$commit" "${commonfile}" "$dest"
      record_file "$dest"
    fi
    log_ok "Grammar '${name}' vendored under ${dest_dir}/${srcdir}/"
  done

  # Hand-authored public bridging headers (not upstream files — declare the
  # exported TSLanguage getter so Swift can see it via the target's public
  # `include/` dir) are recorded in the manifest too, so `--check` also
  # catches accidental edits to them.
  for name in "${GRAMMAR_NAMES[@]}"; do
    local dest_dir symbol module_header
    dest_dir="$(grammar_field "$name" dest)"
    symbol="$(grammar_field "$name" symbol)"
    module_name="$(basename "$dest_dir")"
    module_header="${REPO_ROOT}/${dest_dir}/include/${module_name}.h"
    if [[ -f "$module_header" ]]; then
      record_file "$module_header"
    fi
  done

  write_manifest
}

write_manifest() {
  mkdir -p "$(dirname "$MANIFEST")"

  # `tier2` (M5c, plan §13.2 tier-2) is a hand-curated pin table for the
  # on-demand/long-tail grammars — NOT vendored under Sources/, so this
  # script doesn't fetch or hash-check it. Preserve it verbatim across a
  # regeneration instead of clobbering it (fetch mode only owns
  # `runtime`/`grammars`/`files`).
  local existing_tier2="{}"
  if [[ -f "$MANIFEST" ]] && command -v python3 &>/dev/null; then
    existing_tier2="$(python3 -c "
import json
try:
    with open('${MANIFEST}') as f:
        m = json.load(f)
    print(json.dumps(m.get('tier2', {})))
except Exception:
    print('{}')
")"
  fi

  {
    echo "{"
    echo "  \"_comment\": \"'runtime'/'grammars'/'files' generated by scripts/sync-grammars.sh — do not hand-edit those. 'tier2' is hand-curated (plan §13.2 tier-2) and preserved as-is across regenerations. See docs/CODEGRAPH-PLAN.md §13.2.\","
    echo "  \"runtime\": {"
    echo "    \"repo\": \"${RUNTIME_REPO}\","
    echo "    \"commit\": \"${RUNTIME_COMMIT}\","
    echo "    \"languageVersionMax\": ${RUNTIME_ABI_MAX},"
    echo "    \"languageVersionMin\": ${RUNTIME_ABI_MIN}"
    echo "  },"
    echo "  \"grammars\": {"
    local first=true
    for name in "${GRAMMAR_NAMES[@]}"; do
      $first || echo ","
      first=false
      printf '    "%s": {\n' "$name"
      printf '      "repo": "%s",\n' "$(grammar_field "$name" repo)"
      printf '      "commit": "%s",\n' "$(grammar_field "$name" commit)"
      printf '      "symbol": "%s",\n' "$(grammar_field "$name" symbol)"
      printf '      "abi": %s\n' "$(grammar_field "$name" abi)"
      printf '    }'
    done
    echo ""
    echo "  },"
    echo "  \"files\": {"
    local n=${#MANIFEST_ENTRIES[@]}
    for i in "${!MANIFEST_ENTRIES[@]}"; do
      IFS=$'\t' read -r path sha <<< "${MANIFEST_ENTRIES[$i]}"
      if [[ "$i" -lt $((n - 1)) ]]; then
        printf '    "%s": "%s",\n' "$path" "$sha"
      else
        printf '    "%s": "%s"\n' "$path" "$sha"
      fi
    done
    echo "  },"
    printf '  "tier2": %s\n' "$existing_tier2"
    echo "}"
  } > "$MANIFEST"
  log_ok "Wrote $(echo ${#MANIFEST_ENTRIES[@]}) file hashes to ${MANIFEST} (tier2 section preserved as-is)"
}

if $CHECK_MODE; then
  run_check
else
  run_fetch
fi
