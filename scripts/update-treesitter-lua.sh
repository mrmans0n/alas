#!/usr/bin/env bash
# Re-vendors ThirdParty/TreeSitterLua from tree-sitter-grammars/tree-sitter-lua
# at the tag passed as $1 (default: $DEFAULT_TAG). Upstream's Package.swift
# gates scanner.c behind a relative-path FileManager check that returns false
# during SPM resolution; we ship our own manifest and only refresh the C
# parser + queries + LICENSE here.
set -euo pipefail

DEFAULT_TAG="v0.5.0"
TAG="${1:-$DEFAULT_TAG}"
REPO="https://github.com/tree-sitter-grammars/tree-sitter-lua"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/TreeSitterLua"

if [[ ! -f "$DEST/Package.swift" ]]; then
  echo "error: $DEST/Package.swift missing - refusing to vendor over an unknown directory" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "-> cloning $REPO @ $TAG"
git clone --depth 1 --branch "$TAG" "$REPO" "$TMP/src" >/dev/null 2>&1

SRC="$TMP/src"
for required in \
  src/parser.c src/scanner.c \
  src/tree_sitter/parser.h src/tree_sitter/array.h src/tree_sitter/alloc.h \
  bindings/swift/TreeSitterLua/lua.h \
  queries/highlights.scm \
  LICENSE.md
do
  if [[ ! -f "$SRC/$required" ]]; then
    echo "error: expected file $required missing in upstream at $TAG" >&2
    exit 1
  fi
done

rm -rf "$DEST/src" "$DEST/bindings" "$DEST/queries"
mkdir -p \
  "$DEST/src/tree_sitter" \
  "$DEST/bindings/swift/TreeSitterLua" \
  "$DEST/queries"

install -m 0644 "$SRC/src/parser.c"                         "$DEST/src/parser.c"
install -m 0644 "$SRC/src/scanner.c"                        "$DEST/src/scanner.c"
install -m 0644 "$SRC/src/tree_sitter/parser.h"             "$DEST/src/tree_sitter/parser.h"
install -m 0644 "$SRC/src/tree_sitter/array.h"              "$DEST/src/tree_sitter/array.h"
install -m 0644 "$SRC/src/tree_sitter/alloc.h"              "$DEST/src/tree_sitter/alloc.h"
install -m 0644 "$SRC/bindings/swift/TreeSitterLua/lua.h"   "$DEST/bindings/swift/TreeSitterLua/lua.h"
install -m 0644 "$SRC/queries/highlights.scm"               "$DEST/queries/highlights.scm"
install -m 0644 "$SRC/LICENSE.md"                           "$DEST/LICENSE.md"

REV="$(git -C "$SRC" rev-parse HEAD)"
echo "vendored $TAG ($REV) into ThirdParty/TreeSitterLua"
echo "next: rebuild with \`xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build\`"
