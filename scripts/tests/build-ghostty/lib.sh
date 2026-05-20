#!/usr/bin/env bash
# Test helpers for scripts/build-ghostty.sh. Sourced by every test_*.sh.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"
BUILD_SCRIPT="${REPO_ROOT}/scripts/build-ghostty.sh"
STUB_ZIG="${LIB_DIR}/fixtures/stub-zig.sh"

# Fail-fast assertion helpers. Each prints to stderr and exits 1 on failure.
fail() { echo "FAIL: $*" >&2; exit 1; }
# assert_eq <actual> <expected> <message>
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }
assert_file_exists() { [ -f "$1" ] || fail "missing file: $1"; }
assert_dir_exists() { [ -d "$1" ] || fail "missing dir: $1"; }
assert_not_exists() { [ ! -e "$1" ] || fail "should not exist: $1"; }

# Create an isolated sandbox: fake SRCROOT with a fake ThirdParty/ghostty git
# repo. Returns via globals SANDBOX, SRCROOT, GHOSTTY_DIR, CACHE_DIR.
setup_sandbox() {
  SANDBOX="$(mktemp -d -t alas-ghostty-test.XXXXXX)"
  SRCROOT="${SANDBOX}/srcroot"
  GHOSTTY_DIR="${SRCROOT}/ThirdParty/ghostty"
  CACHE_DIR="${SANDBOX}/cache"
  STUB_LOG="${SANDBOX}/stub-zig.log"
  mkdir -p "${GHOSTTY_DIR}" "${CACHE_DIR}"

  # Fake submodule must be a real git repo so print_fingerprint's git calls work.
  (
    cd "${GHOSTTY_DIR}"
    git init -q
    git config user.email test@example.com
    git config user.name test
    : > build.zig
    # Ignore the xcframework and zig-out paths that the build script / stub create
    # inside this directory, so they don't perturb the fingerprint between runs.
    printf '/macos/GhosttyKit.xcframework/\n/zig-out/\n/.zig-cache/\n' > .gitignore
    git add build.zig .gitignore
    git commit -q -m initial
  )

  # mise.toml is read by print_fingerprint when present.
  : > "${SRCROOT}/mise.toml"

  # Worktree-equivalent .build dir
  mkdir -p "${SRCROOT}/.build"
}

teardown_sandbox() {
  if [ -n "${SANDBOX:-}" ] && [ -d "${SANDBOX}" ]; then
    # Restore permissions on any subdirectories that may have been made
    # unwritable/unreadable by a test (e.g. chmod 000) before the recursive
    # chmod. On macOS, chmod -R cannot descend into mode-000 directories even
    # when the caller owns them, so we must chmod each entry individually first.
    # Use the system find directly to avoid any PATH-wrapper interference.
    /usr/bin/find "${SANDBOX}" -mindepth 1 -maxdepth 2 -type d \
      -exec chmod u+rwx {} + 2>/dev/null || true
    chmod -R u+w "${SANDBOX}" 2>/dev/null || true
    rm -rf "${SANDBOX}"
  fi
}

# Invoke build-ghostty.sh with hermetic env. Extra args/env can be passed.
run_build_script() {
  env -i \
    HOME="${SANDBOX}/home" \
    PATH="${PATH}" \
    SRCROOT="${SRCROOT}" \
    ALAS_ZIG_BIN="${STUB_ZIG}" \
    ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
    STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
    "$@" \
    "${BUILD_SCRIPT}"
}

# Count how many times the stub zig was invoked across the lifetime of this
# sandbox. Each invocation appends a line to STUB_ZIG_INVOCATION_LOG.
stub_invocations() {
  [ -f "${STUB_LOG}" ] && wc -l < "${STUB_LOG}" | tr -d ' ' || echo 0
}
