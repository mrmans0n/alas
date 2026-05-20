#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox
# Make the cache root unwritable.
chmod 000 "${CACHE_DIR}"

run_build_script
assert_eq "$(stub_invocations)" "1" "built locally despite unwritable cache"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
