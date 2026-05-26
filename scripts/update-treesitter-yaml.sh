#!/usr/bin/env bash
# Re-vendors ThirdParty/TreeSitterYAML from tree-sitter-grammars/tree-sitter-yaml
# at the tag passed as $1 (default: $DEFAULT_TAG). The upstream Package.swift
# guards its scanner.c source behind a relative-path FileManager check that
# fails during SPM resolution, so we ship our own Package.swift and only refresh
# the C parser + queries + LICENSE from upstream.
set -euo pipefail

DEFAULT_TAG="v0.7.2"
TAG="${1:-$DEFAULT_TAG}"
REPO="https://github.com/tree-sitter-grammars/tree-sitter-yaml"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/TreeSitterYAML"

if [[ ! -f "$DEST/Package.swift" ]]; then
  echo "error: $DEST/Package.swift missing — refusing to vendor over an unknown directory" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ cloning $REPO @ $TAG"
git clone --depth 1 --branch "$TAG" "$REPO" "$TMP/src" >/dev/null 2>&1

SRC="$TMP/src"
for required in \
  src/parser.c src/scanner.c \
  src/schema.core.c src/schema.json.c src/schema.legacy.c \
  src/tree_sitter/parser.h src/tree_sitter/array.h src/tree_sitter/alloc.h \
  bindings/swift/TreeSitterYAML/yaml.h \
  queries/highlights.scm \
  LICENSE
do
  if [[ ! -f "$SRC/$required" ]]; then
    echo "error: expected file $required missing in upstream at $TAG" >&2
    exit 1
  fi
done

# Wipe the tracked subtrees we replace (preserves Package.swift + this script's edits).
rm -rf \
  "$DEST/src" \
  "$DEST/bindings" \
  "$DEST/queries"

mkdir -p \
  "$DEST/src/tree_sitter" \
  "$DEST/bindings/swift/TreeSitterYAML" \
  "$DEST/queries"

install -m 0644 "$SRC/src/parser.c"               "$DEST/src/parser.c"
install -m 0644 "$SRC/src/scanner.c"              "$DEST/src/scanner.c"
install -m 0644 "$SRC/src/schema.core.c"          "$DEST/src/schema.core.c"
install -m 0644 "$SRC/src/schema.json.c"          "$DEST/src/schema.json.c"
install -m 0644 "$SRC/src/schema.legacy.c"        "$DEST/src/schema.legacy.c"
install -m 0644 "$SRC/src/tree_sitter/parser.h"   "$DEST/src/tree_sitter/parser.h"
install -m 0644 "$SRC/src/tree_sitter/array.h"    "$DEST/src/tree_sitter/array.h"
install -m 0644 "$SRC/src/tree_sitter/alloc.h"    "$DEST/src/tree_sitter/alloc.h"
install -m 0644 "$SRC/bindings/swift/TreeSitterYAML/yaml.h" "$DEST/bindings/swift/TreeSitterYAML/yaml.h"
install -m 0644 "$SRC/queries/highlights.scm"     "$DEST/queries/highlights.scm"
install -m 0644 "$SRC/LICENSE"                    "$DEST/LICENSE"

REV="$(git -C "$SRC" rev-parse HEAD)"
echo "✓ vendored $TAG ($REV) into ThirdParty/TreeSitterYAML"
echo "  next: rebuild with \`xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build\`"
