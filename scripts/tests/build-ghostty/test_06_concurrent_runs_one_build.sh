#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

# Spin up a SECOND worktree against the same fake submodule but its own
# .build dir. Both will compute the same fingerprint.
SRCROOT2="${SANDBOX}/srcroot2"
mkdir -p "${SRCROOT2}/.build"
ln -s "${SRCROOT}/ThirdParty" "${SRCROOT2}/ThirdParty"
cp "${SRCROOT}/mise.toml" "${SRCROOT2}/mise.toml"

# Slow the stub down so the race is observable.
run_slow() {
  local srcroot="$1"
  env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
    SRCROOT="${srcroot}" ALAS_ZIG_BIN="${STUB_ZIG}" \
    ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
    STUB_ZIG_INVOCATION_LOG="${STUB_LOG}" \
    STUB_ZIG_SLEEP=2 \
    "${BUILD_SCRIPT}"
}

run_slow "${SRCROOT}" &
pid1=$!
sleep 0.2  # let pid1 acquire the lock
run_slow "${SRCROOT2}" &
pid2=$!
wait "${pid1}"
wait "${pid2}"

assert_eq "$(stub_invocations)" "1" "exactly one zig invocation under concurrency"

arch="$(uname -m)"
fp="$(ls "${CACHE_DIR}/${arch}")"
# Expect exactly one entry (the published one). No lock dir, no staging dirs.
[ "$(echo "${fp}" | wc -l | tr -d ' ')" = "1" ] || fail "expected one cache entry"
assert_not_exists "${CACHE_DIR}/${arch}/${fp}.lock"
[ -z "$(find "${CACHE_DIR}/${arch}" -maxdepth 1 -name "${fp}.tmp.*" -print -quit)" ] \
  || fail "leftover staging dir"

# Both worktrees have populated artifacts.
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
assert_dir_exists "${SRCROOT2}/.build/ghostty/GhosttyKit.xcframework"
