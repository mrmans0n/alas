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

# Plant a partial entry: fingerprint + xcframework exist, but share/ does not.
mkdir -p "${entry}/GhosttyKit.xcframework"
printf '%s\n' "${fp}" > "${entry}/fingerprint"

run_build_script
assert_eq "$(stub_invocations)" "1" "partial entry must trigger rebuild"
assert_dir_exists "${entry}/share/ghostty"
