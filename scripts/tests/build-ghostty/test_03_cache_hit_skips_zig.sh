#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

# Compute the fingerprint without running a build.
fp="$(env -i HOME="${SANDBOX}/home" PATH="${PATH}" \
  SRCROOT="${SRCROOT}" ALAS_ZIG_BIN="${STUB_ZIG}" \
  ALAS_GHOSTTY_CACHE_DIR="${CACHE_DIR}" \
  "${BUILD_SCRIPT}" --print-fingerprint)"

# Pre-populate the shared cache as if a prior worktree had published.
arch="$(uname -m)"
entry="${CACHE_DIR}/${arch}/${fp}"
mkdir -p "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers"
echo "cached-marker" > "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers/ghostty.h"
cat > "${entry}/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers/module.modulemap" <<EOF
module GhosttyKit {
    header "ghostty.h"
    export *
}
EOF
cat > "${entry}/GhosttyKit.xcframework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>
EOF
mkdir -p "${entry}/share/ghostty" "${entry}/share/terminfo"
echo "cached-share-ghostty" > "${entry}/share/ghostty/marker"
echo "cached-share-terminfo" > "${entry}/share/terminfo/marker"
printf '%s\n' "${fp}" > "${entry}/fingerprint"

# Run the build: should populate from cache, no zig invocations.
run_build_script
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"
assert_eq "$(cat "${SRCROOT}/.build/ghostty/share/ghostty/marker")" \
  "cached-share-ghostty" "share populated from cache, not stub"
assert_eq "$(cat "${SRCROOT}/.build/ghostty/fingerprint")" "${fp}" "local fp matches"
assert_eq "$(stub_invocations)" "0" "zig not invoked on cache hit"
