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
lock_dir="${CACHE_DIR}/${arch}/${fp}.lock"

# Plant a stale lock: PID that definitely isn't running, mtime older than 60s.
mkdir -p "${lock_dir}"
echo 999999 > "${lock_dir}/pid"
# Backdate the lock dir's mtime by 120 seconds. macOS `date -v-2M`, GNU `date -d`.
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${lock_dir}"

# For the test, allow short stale-lock grace.
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  "${BUILD_SCRIPT}"

assert_eq "$(stub_invocations)" "1" "rebuilt after taking over stale lock"
assert_not_exists "${lock_dir}"
assert_dir_exists "${CACHE_DIR}/${arch}/${fp}"
