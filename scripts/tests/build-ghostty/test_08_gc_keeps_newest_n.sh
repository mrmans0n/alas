#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox
arch="$(uname -m)"
arch_dir="${CACHE_DIR}/${arch}"
mkdir -p "${arch_dir}"

# Plant 6 fake entries with staggered mtimes (oldest to newest).
for i in 1 2 3 4 5 6; do
  d="${arch_dir}/fake_fp_${i}"
  mkdir -p "${d}/GhosttyKit.xcframework" "${d}/share/ghostty" "${d}/share/terminfo"
  echo "fake_fp_${i}" > "${d}/fingerprint"
  touch -t "$(date -v-${i}H +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d "${i} hours ago" +%Y%m%d%H%M.%S)" "${d}"
done

# Plant one extra entry holding an active lock; it must NOT be evicted.
d="${arch_dir}/fake_fp_locked"
mkdir -p "${d}/GhosttyKit.xcframework" "${d}/share/ghostty" "${d}/share/terminfo"
echo "fake_fp_locked" > "${d}/fingerprint"
touch -t "$(date -v-10H +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '10 hours ago' +%Y%m%d%H%M.%S)" "${d}"
mkdir "${arch_dir}/fake_fp_locked.lock"

# Now run a real build, which publishes a 7th entry and triggers GC with keep=5.
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_CACHE_KEEP=5 \
  "${BUILD_SCRIPT}"

# After GC: 5 newest-by-mtime remain among the gc-able entries
# (fake_fp_1..6 + the just-published real one = 7 candidates; keep 5).
# fake_fp_1 (1h old) and fake_fp_2 (2h old) are the newest fakes; the
# just-published real one is newest of all; so we expect to keep:
#   real_just_published, fake_fp_1, fake_fp_2, fake_fp_3, fake_fp_4
# and to drop fake_fp_5 and fake_fp_6.
# fake_fp_locked is excluded from GC entirely due to its sibling .lock dir.
assert_not_exists "${arch_dir}/fake_fp_5"
assert_not_exists "${arch_dir}/fake_fp_6"
assert_dir_exists "${arch_dir}/fake_fp_1"
assert_dir_exists "${arch_dir}/fake_fp_4"
assert_dir_exists "${arch_dir}/fake_fp_locked"

echo "PASS"
