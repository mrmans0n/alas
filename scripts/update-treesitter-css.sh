#!/usr/bin/env bash
# Re-vendors ThirdParty/TreeSitterCSS from tree-sitter/tree-sitter-css
# at the tag passed as $1 (default: $DEFAULT_TAG). Upstream's Package.swift
# gates scanner.c behind a relative-path FileManager check that returns false
# during SPM resolution; we ship our own manifest and only refresh the C
# parser + queries + LICENSE here.
set -euo pipefail

DEFAULT_TAG="v0.25.0"
TAG="${1:-$DEFAULT_TAG}"
REPO="https://github.com/tree-sitter/tree-sitter-css"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/TreeSitterCSS"

if [[ ! -f "$DEST/Package.swift" ]]; then
  echo "error: $DEST/Package.swift missing - refusing to vendor over an unknown directory" >&2
  exit 1
fi

TMP="$(mktemp -d)"
STAGE=""
cleanup() {
  rm -rf "$TMP"
  if [[ -n "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT

echo "-> cloning $REPO @ $TAG"
git clone --depth 1 --branch "$TAG" "$REPO" "$TMP/src" >/dev/null 2>&1

SRC="$TMP/src"
for required in \
  src/parser.c src/scanner.c \
  src/tree_sitter/parser.h src/tree_sitter/array.h src/tree_sitter/alloc.h \
  bindings/swift/TreeSitterCSS/css.h \
  queries/highlights.scm \
  LICENSE
do
  if [[ ! -f "$SRC/$required" ]]; then
    echo "error: expected file $required missing in upstream at $TAG" >&2
    exit 1
  fi
done

STAGE="$(mktemp -d "$DEST/.update-treesitter-css.XXXXXX")"
mkdir -p \
  "$STAGE/src/tree_sitter" \
  "$STAGE/bindings/swift/TreeSitterCSS" \
  "$STAGE/queries"

install -m 0644 "$SRC/src/parser.c"                         "$STAGE/src/parser.c"
install -m 0644 "$SRC/src/scanner.c"                        "$STAGE/src/scanner.c"
install -m 0644 "$SRC/src/tree_sitter/parser.h"             "$STAGE/src/tree_sitter/parser.h"
install -m 0644 "$SRC/src/tree_sitter/array.h"              "$STAGE/src/tree_sitter/array.h"
install -m 0644 "$SRC/src/tree_sitter/alloc.h"              "$STAGE/src/tree_sitter/alloc.h"
install -m 0644 "$SRC/bindings/swift/TreeSitterCSS/css.h"   "$STAGE/bindings/swift/TreeSitterCSS/css.h"
install -m 0644 "$SRC/queries/highlights.scm"               "$STAGE/queries/highlights.scm"
install -m 0644 "$SRC/LICENSE"                              "$STAGE/LICENSE"

rm -rf "$DEST/src" "$DEST/bindings" "$DEST/queries"
mv "$STAGE/src" "$DEST/src"
mv "$STAGE/bindings" "$DEST/bindings"
mv "$STAGE/queries" "$DEST/queries"
mv "$STAGE/LICENSE" "$DEST/LICENSE"

REV="$(git -C "$SRC" rev-parse HEAD)"
echo "vendored $TAG ($REV) into ThirdParty/TreeSitterCSS"
echo "next: rebuild with \`xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build\`"
