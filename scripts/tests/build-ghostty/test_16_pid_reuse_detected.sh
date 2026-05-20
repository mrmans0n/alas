#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P1: PID reuse must be detected. We can't easily synthesize a real
# reuse, so we simulate it: plant a lock whose PID file references this very
# test process (alive!) but with a bogus start-time token that cannot match
# the real `ps -o lstart=` output. The script must treat this as "holder
# gone" and reclaim, instead of trusting `kill -0` alone.

setup_sandbox
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
lock_dir="${CACHE_DIR}/${arch}/${fp}.lock"

mkdir -p "${lock_dir}"
# Use our own PID (definitely alive) with a deliberately-wrong start token.
printf '%s %s\n' "$$" "Jan 01 00:00:00 1970" > "${lock_dir}/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${lock_dir}"

env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  "${BUILD_SCRIPT}"

assert_eq "$(stub_invocations)" "1" "rebuilt after detecting PID-reuse"
assert_not_exists "${lock_dir}"
assert_dir_exists "${CACHE_DIR}/${arch}/${fp}"
