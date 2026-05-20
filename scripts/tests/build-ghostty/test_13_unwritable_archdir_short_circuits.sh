#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P1: if the parent arch dir exists but is unwritable (e.g. previously
# created by sudo), acquire_cache_lock would treat the EACCES on mkdir as
# contention and stall for the full ALAS_GHOSTTY_LOCK_TIMEOUT_SECS. Verify it
# now short-circuits to a local-only build.

setup_sandbox
arch="$(uname -m)"
arch_dir="${CACHE_DIR}/${arch}"
mkdir -p "${arch_dir}"
chmod 555 "${arch_dir}"

start="$(date +%s)"
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_TIMEOUT_SECS=120 \
  "${BUILD_SCRIPT}"
elapsed=$(( $(date +%s) - start ))

assert_eq "$(stub_invocations)" "1" "built locally despite unwritable arch dir"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
# Must NOT have stalled near the 120s timeout. Generous bound to absorb stub
# build time, but well short of even a 30s wait.
[ "${elapsed}" -lt 30 ] || fail "expected short-circuit, took ${elapsed}s"
