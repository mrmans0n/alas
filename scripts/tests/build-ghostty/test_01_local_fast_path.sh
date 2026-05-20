#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

# First run: cold. Stub zig builds; .build/ghostty populated.
run_build_script
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
assert_file_exists "${SRCROOT}/.build/ghostty/fingerprint"
assert_eq "$(stub_invocations)" "1" "zig invoked once on cold build"

# Second run: local fast path. Stub zig MUST NOT be invoked.
run_build_script
assert_eq "$(stub_invocations)" "1" "zig not invoked when local fingerprint matches"
