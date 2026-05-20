#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P1: if a stale lock dir is detected but rm -rf can't remove it
# (e.g. EACCES on a sudo-owned cache), the lock loop must short-circuit
# instead of spinning to the timeout.

setup_sandbox
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
arch_dir="${CACHE_DIR}/${arch}"
lock_dir="${arch_dir}/${fp}.lock"

# Plant a stale lock and make the parent arch dir non-writable so the
# script CAN stat the lock (parent is r-x) but CANNOT remove its entries.
mkdir -p "${lock_dir}"
echo 999999 > "${lock_dir}/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${lock_dir}"
chmod 555 "${arch_dir}"

start="$(date +%s)"
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  ALAS_GHOSTTY_LOCK_TIMEOUT_SECS=120 \
  "${BUILD_SCRIPT}"
elapsed=$(( $(date +%s) - start ))

assert_eq "$(stub_invocations)" "1" "built locally despite unremovable stale lock"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
[ "${elapsed}" -lt 30 ] || fail "expected short-circuit, took ${elapsed}s"
