#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex feedback: a publisher killed between `mv` and `rmdir` leaves a stale
# lock dir next to a valid cache entry. The cache-hit fast path bypasses
# acquire_cache_lock, so without an opportunistic sweep the lock would persist
# forever, and gc_cache would refuse to ever evict the entry (it skips entries
# with a sibling .lock dir).

setup_sandbox
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
entry="${CACHE_DIR}/${arch}/${fp}"
lock_dir="${entry}.lock"

# Plant a valid cache entry + a stale lock from a dead publisher.
mkdir -p "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers" \
         "${entry}/share/ghostty" "${entry}/share/terminfo"
echo "cached" > "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers/ghostty.h"
cat > "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers/module.modulemap" <<'EOF'
module GhosttyKit { header "ghostty.h" export * }
EOF
echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "${entry}/GhosttyKit.xcframework/Info.plist"
echo "cached" > "${entry}/share/ghostty/marker"
echo "cached" > "${entry}/share/terminfo/marker"
printf '%s\n' "${fp}" > "${entry}/fingerprint"

mkdir "${lock_dir}"
echo 999999 > "${lock_dir}/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d '120 seconds ago' +%Y%m%d%H%M.%S)" "${lock_dir}"

# Short stale-lock grace so the sweep fires.
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_STALE_SECS=10 \
  "${BUILD_SCRIPT}"

assert_eq "$(stub_invocations)" "0" "cache-hit path skipped zig"
assert_not_exists "${lock_dir}"
assert_dir_exists "${entry}"
