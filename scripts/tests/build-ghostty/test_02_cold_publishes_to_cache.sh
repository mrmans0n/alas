#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
entry="${CACHE_DIR}/${arch}/${fp}"

# First run: cold cache. Build + publish.
run_build_script
assert_eq "$(stub_invocations)" "1" "zig built once"
assert_dir_exists "${entry}/GhosttyKit.xcframework"
assert_dir_exists "${entry}/share/ghostty"
assert_dir_exists "${entry}/share/terminfo"
assert_eq "$(cat "${entry}/fingerprint")" "${fp}" "cache fingerprint matches"
assert_not_exists "${CACHE_DIR}/${arch}/${fp}.lock"
# No leftover staging dirs
[ -z "$(find "${CACHE_DIR}/${arch}" -maxdepth 1 -name "${fp}.tmp.*" -print -quit)" ] \
  || fail "leftover staging dir"

# Second run: nuke .build/ghostty so the local fast path fails, then verify
# we restore from the cache we just published, with no new zig invocation.
rm -rf "${SRCROOT}/.build/ghostty"
run_build_script
assert_eq "$(stub_invocations)" "1" "second run used cache, did not build"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
