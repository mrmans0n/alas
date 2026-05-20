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

# Manually create an entry whose `fingerprint` file says something else.
mkdir -p "${entry}/GhosttyKit.xcframework" "${entry}/share/ghostty" "${entry}/share/terminfo"
echo "WRONG_FINGERPRINT" > "${entry}/fingerprint"

run_build_script
assert_eq "$(stub_invocations)" "1" "stale entry must trigger rebuild"
# After the build, the entry should be replaced with the correct fingerprint
assert_eq "$(cat "${entry}/fingerprint")" "${fp}" "republished with correct fp"
