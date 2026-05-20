#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P2: a lock metadata file containing only a PID (no start-time token)
# must NOT be parsed as if the PID were also the token. Otherwise an alive
# lock holder's start-time would be compared against the PID string and never
# match, causing a false stale-lock reclamation while the lock is genuinely
# held. Plant a pid-only lock referencing this test process (definitely
# alive) and assert the script does NOT reclaim it — instead it should sit
# and wait, which we detect by giving it a tiny timeout and asserting that
# the lock dir survives.

setup_sandbox
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
lock_dir="${CACHE_DIR}/${arch}/${fp}.lock"

mkdir -p "${lock_dir}"
# PID-only: no start token recorded. Our PID is alive.
printf '%s\n' "$$" > "${lock_dir}/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${lock_dir}"

# Run with a short timeout (5s). Lock is "alive" so the script will wait
# until the deadline, then fall back to local build. The KEY assertion:
# the lock dir was NOT reclaimed (which would be a false-positive).
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  ALAS_GHOSTTY_LOCK_TIMEOUT_SECS=5 \
  "${BUILD_SCRIPT}"

assert_dir_exists "${lock_dir}"
assert_eq "$(stub_invocations)" "1" "fell back to local build after timeout"
