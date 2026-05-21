#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

# Build with explicit target arch override (cross-compile path).
run_build_script ALAS_GHOSTTY_TARGET_ARCH=x86_64

# Stub zig should have been invoked once and seen the -Dtarget flag.
assert_eq "$(stub_invocations)" "1" "zig invoked once on cold build"
target_seen="$(cat "${SANDBOX}/stub-zig.target.log" 2>/dev/null || echo '')"
assert_eq "${target_seen}" "x86_64-macos.14.0" "stub-zig saw -Dtarget=x86_64-macos.14.0 for x86_64 build"

# Shared cache must be keyed under the TARGET arch, not the host arch.
assert_dir_exists "${CACHE_DIR}/x86_64"
host_arch="$(uname -m)"
if [ "${host_arch}" != "x86_64" ]; then
  assert_not_exists "${CACHE_DIR}/${host_arch}"
fi

# Cold rebuild after wiping the worktree fingerprint but keeping the cache.
# Same target arch must hit the cache (one prior invocation, still one now).
rm -f "${SRCROOT}/.build/ghostty/fingerprint"
run_build_script ALAS_GHOSTTY_TARGET_ARCH=x86_64
assert_eq "$(stub_invocations)" "1" "shared cache hit for x86_64 skips zig"

# Switching the target arch must produce a different fingerprint and rebuild.
run_build_script ALAS_GHOSTTY_TARGET_ARCH=arm64
assert_eq "$(stub_invocations)" "2" "different target arch forces rebuild"
assert_dir_exists "${CACHE_DIR}/arm64"
target_seen_arm="$(cat "${SANDBOX}/stub-zig.target.log" 2>/dev/null || echo '')"
assert_eq "${target_seen_arm}" "aarch64-macos.14.0" "stub-zig saw -Dtarget=aarch64-macos.14.0 for arm64 build (translated from Apple name)"

# Direct fingerprint comparison: confirms target_arch participates in the
# fingerprint (catches regressions where someone removes target_arch from
# print_fingerprint without breaking the count-based assertions above).
fp_x86="$(env -i \
  HOME="${SANDBOX}/home" \
  PATH="${PATH}" \
  SRCROOT="${SRCROOT}" \
  ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  ALAS_GHOSTTY_TARGET_ARCH=x86_64 \
  "${BUILD_SCRIPT}" --print-fingerprint)"

fp_arm="$(env -i \
  HOME="${SANDBOX}/home" \
  PATH="${PATH}" \
  SRCROOT="${SRCROOT}" \
  ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  ALAS_GHOSTTY_TARGET_ARCH=arm64 \
  "${BUILD_SCRIPT}" --print-fingerprint)"

[ "${fp_x86}" != "${fp_arm}" ] || fail "fingerprint identical for x86_64 and arm64"
