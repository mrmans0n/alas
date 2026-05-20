#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex follow-up: gc_cache must reclaim stale sibling locks. Without this,
# an entry whose fingerprint is never requested again (so the cache-hit
# fast-path sweep from test_11 never fires) stays pinned forever even if
# the lock's owner died.

setup_sandbox
arch="$(uname -m)"
arch_dir="${CACHE_DIR}/${arch}"
mkdir -p "${arch_dir}"

# Plant 5 fresh fake entries + one OLD entry with a STALE sibling lock.
# With keep=5 and the about-to-be-published real entry, the stale-locked
# entry should be the oldest and must be evicted (proving the lock was
# reclaimed and the entry was made eligible for GC).
for i in 1 2 3 4 5; do
  d="${arch_dir}/fake_fp_${i}"
  mkdir -p "${d}/GhosttyKit.xcframework" "${d}/share/ghostty" "${d}/share/terminfo"
  echo "fake_fp_${i}" > "${d}/fingerprint"
  touch -t "$(date -v-${i}M +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d "${i} minutes ago" +%Y%m%d%H%M.%S)" "${d}"
done

stale="${arch_dir}/fake_fp_stale_locked"
mkdir -p "${stale}/GhosttyKit.xcframework" "${stale}/share/ghostty" "${stale}/share/terminfo"
echo "fake_fp_stale_locked" > "${stale}/fingerprint"
touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '2 hours ago' +%Y%m%d%H%M.%S)" "${stale}"
mkdir "${stale}.lock"
echo 999999 > "${stale}.lock/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${stale}.lock"

env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_CACHE_KEEP=5 \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  "${BUILD_SCRIPT}"

# The stale lock dir must be removed by gc's reclamation sweep.
assert_not_exists "${stale}.lock"
# And the orphaned entry, now eligible AND the oldest, must be evicted.
assert_not_exists "${stale}"
# The freshly-published entry survives.
assert_dir_exists "${arch_dir}/fake_fp_1"
