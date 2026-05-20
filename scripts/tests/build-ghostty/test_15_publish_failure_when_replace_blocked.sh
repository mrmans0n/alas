#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

# Codex P2: when rm cannot remove a stale entry (e.g. parent unwritable) AND
# the entry left behind does not carry our fingerprint, publish_to_cache must
# report failure so the caller warns and skips GC instead of pretending the
# cache was refreshed.

setup_sandbox
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"
arch="$(uname -m)"
arch_dir="${CACHE_DIR}/${arch}"
entry="${arch_dir}/${fp}"

# Plant a stale entry with the WRONG fingerprint, and make the arch dir
# read-only so neither the entry nor its contents can be removed.
mkdir -p "${entry}/GhosttyKit.xcframework" "${entry}/share/ghostty" "${entry}/share/terminfo"
echo "WRONG_FP" > "${entry}/fingerprint"
chmod 555 "${arch_dir}"

# Run the build. Capture stderr to assert that we see the publish-failure
# warning (which would NOT fire if publish_to_cache lied about success).
log="${SANDBOX}/build.err"
env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
  ALAS_GHOSTTY_LOCK_TIMEOUT_SECS=120 \
  "${BUILD_SCRIPT}" 2>"${log}"

assert_eq "$(stub_invocations)" "1" "build ran"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"

# The script's fallback path warns either at lock-acquire or publish stage;
# both are valid outcomes that prove publish_to_cache did not silently lie.
# The forbidden state is: no warning AND a stale entry with WRONG_FP.
grep -qE "could not acquire shared cache lock|cannot create lock dir|failed to publish to shared cache" "${log}" \
  || fail "expected a cache-failure warning in stderr; got: $(cat "${log}")"

# The stale entry's fingerprint should be unchanged (rm could not remove it).
chmod 755 "${arch_dir}"
assert_eq "$(cat "${entry}/fingerprint")" "WRONG_FP" "stale entry untouched"
