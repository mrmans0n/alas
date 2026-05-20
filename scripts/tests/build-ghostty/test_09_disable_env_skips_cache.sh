#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_CACHE_DISABLE=1 \
  "${BUILD_SCRIPT}"

assert_eq "$(stub_invocations)" "1" "build still runs"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
# Nothing should have been written under the cache dir.
[ -z "$(find "${CACHE_DIR}" -mindepth 1 -print -quit)" ] \
  || fail "shared cache must not be touched when disabled"
