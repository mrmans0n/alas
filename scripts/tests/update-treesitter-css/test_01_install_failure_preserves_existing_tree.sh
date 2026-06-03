#!/usr/bin/env bash
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_contains() {
  local file="$1"
  local expected="$2"
  [ -f "$file" ] || fail "missing file: $file"
  grep -qxF "$expected" "$file" || fail "expected $file to contain '$expected'"
}

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
SANDBOX="$(mktemp -d -t alas-css-vendor-test.XXXXXX)"
trap 'chmod -R u+w "${SANDBOX}" 2>/dev/null || true; rm -rf "${SANDBOX}"' EXIT

SCRIPT_ROOT="${SANDBOX}/repo"
DEST="${SCRIPT_ROOT}/ThirdParty/TreeSitterCSS"
UPSTREAM="${SANDBOX}/upstream"
BIN="${SANDBOX}/bin"

mkdir -p \
  "${SCRIPT_ROOT}/scripts" \
  "${DEST}/src/tree_sitter" \
  "${DEST}/bindings/swift/TreeSitterCSS" \
  "${DEST}/queries" \
  "${UPSTREAM}/src/tree_sitter" \
  "${UPSTREAM}/bindings/swift/TreeSitterCSS" \
  "${UPSTREAM}/queries" \
  "${BIN}"

ln -s "${REPO_ROOT}/scripts/update-treesitter-css.sh" "${SCRIPT_ROOT}/scripts/update-treesitter-css.sh"

printf 'manifest\n' > "${DEST}/Package.swift"
printf 'old parser\n' > "${DEST}/src/parser.c"
printf 'old scanner\n' > "${DEST}/src/scanner.c"
printf 'old parser header\n' > "${DEST}/src/tree_sitter/parser.h"
printf 'old array header\n' > "${DEST}/src/tree_sitter/array.h"
printf 'old alloc header\n' > "${DEST}/src/tree_sitter/alloc.h"
printf 'old swift header\n' > "${DEST}/bindings/swift/TreeSitterCSS/css.h"
printf 'old query\n' > "${DEST}/queries/highlights.scm"
printf 'old license\n' > "${DEST}/LICENSE"

printf 'new parser\n' > "${UPSTREAM}/src/parser.c"
printf 'new scanner\n' > "${UPSTREAM}/src/scanner.c"
printf 'new parser header\n' > "${UPSTREAM}/src/tree_sitter/parser.h"
printf 'new array header\n' > "${UPSTREAM}/src/tree_sitter/array.h"
printf 'new alloc header\n' > "${UPSTREAM}/src/tree_sitter/alloc.h"
printf 'new swift header\n' > "${UPSTREAM}/bindings/swift/TreeSitterCSS/css.h"
printf 'new query\n' > "${UPSTREAM}/queries/highlights.scm"
printf 'new license\n' > "${UPSTREAM}/LICENSE"

cat > "${BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "clone" ]; then
  dest=""
  for arg in "$@"; do
    dest="$arg"
  done
  mkdir -p "$dest"
  cp -R "${FAKE_UPSTREAM}/." "$dest"
  exit 0
fi
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then
  printf 'fake-revision\n'
  exit 0
fi
echo "unexpected git invocation: $*" >&2
exit 1
EOF

cat > "${BIN}/install" <<'EOF'
#!/usr/bin/env bash
echo "forced install failure" >&2
exit 42
EOF
chmod +x "${BIN}/git" "${BIN}/install"

if env -i PATH="${BIN}:${PATH}" FAKE_UPSTREAM="${UPSTREAM}" \
  bash "${SCRIPT_ROOT}/scripts/update-treesitter-css.sh" test-tag >/dev/null 2>"${SANDBOX}/script.err"; then
  fail "expected update-treesitter-css.sh to fail"
fi

assert_file_contains "${DEST}/src/parser.c" "old parser"
assert_file_contains "${DEST}/src/scanner.c" "old scanner"
assert_file_contains "${DEST}/src/tree_sitter/parser.h" "old parser header"
assert_file_contains "${DEST}/src/tree_sitter/array.h" "old array header"
assert_file_contains "${DEST}/src/tree_sitter/alloc.h" "old alloc header"
assert_file_contains "${DEST}/bindings/swift/TreeSitterCSS/css.h" "old swift header"
assert_file_contains "${DEST}/queries/highlights.scm" "old query"
assert_file_contains "${DEST}/LICENSE" "old license"
