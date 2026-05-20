#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P2: the fingerprint must capture zig toolchain identity so a worktree
# using one zig binary cannot share artifacts with a worktree using another.

setup_sandbox

# Make a second stub zig with different content (but same interface).
alt_zig="${SANDBOX}/alt-zig.sh"
cp "${STUB_ZIG}" "${alt_zig}"
echo "# alt-zig variant" >> "${alt_zig}"
chmod +x "${alt_zig}"

fp_default="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"

fp_alt="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${alt_zig}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"

[ "${fp_default}" != "${fp_alt}" ] \
  || fail "fingerprint did not change when ALAS_ZIG_BIN swapped to different content (${fp_default})"
