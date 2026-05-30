#!/usr/bin/env bash
# Re-vendors ThirdParty/TreeSitterHCL from tree-sitter-grammars/tree-sitter-hcl
# at the tag passed as $1 (default: $DEFAULT_TAG). Upstream's Package.swift
# does not bundle query resources, so this keeps the local Package.swift and
# queries/highlights.scm while refreshing parser sources and LICENSE.
set -euo pipefail

DEFAULT_TAG="v1.2.0"
TAG="${1:-$DEFAULT_TAG}"
REPO="https://github.com/tree-sitter-grammars/tree-sitter-hcl"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/TreeSitterHCL"

if [[ ! -f "$DEST/Package.swift" || ! -f "$DEST/queries/highlights.scm" ]]; then
  echo "error: $DEST missing local manifest or query - refusing to vendor over an unknown directory" >&2
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
  bindings/swift/TreeSitterHCL/hcl.h \
  LICENSE
do
  if [[ ! -f "$SRC/$required" ]]; then
    echo "error: expected file $required missing in upstream at $TAG" >&2
    exit 1
  fi
done

rm -rf "$DEST/src" "$DEST/bindings"
mkdir -p \
  "$DEST/src/tree_sitter" \
  "$DEST/bindings/swift/TreeSitterHCL"

install -m 0644 "$SRC/src/parser.c"                         "$DEST/src/parser.c"
install -m 0644 "$SRC/src/scanner.c"                        "$DEST/src/scanner.c"
install -m 0644 "$SRC/src/tree_sitter/parser.h"             "$DEST/src/tree_sitter/parser.h"
install -m 0644 "$SRC/src/tree_sitter/array.h"              "$DEST/src/tree_sitter/array.h"
install -m 0644 "$SRC/src/tree_sitter/alloc.h"              "$DEST/src/tree_sitter/alloc.h"
install -m 0644 "$SRC/bindings/swift/TreeSitterHCL/hcl.h"   "$DEST/bindings/swift/TreeSitterHCL/hcl.h"
install -m 0644 "$SRC/LICENSE"                              "$DEST/LICENSE"

REV="$(git -C "$SRC" rev-parse HEAD)"
echo "vendored $TAG ($REV) into ThirdParty/TreeSitterHCL"
echo "next: rebuild with \`xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build\`"
