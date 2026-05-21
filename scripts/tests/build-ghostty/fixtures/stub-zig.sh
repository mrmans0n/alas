#!/usr/bin/env bash
set -euo pipefail

# Log this invocation so tests can count zig calls.
if [ -n "${STUB_ZIG_INVOCATION_LOG:-}" ]; then
  echo "$(date +%s) $*" >> "${STUB_ZIG_INVOCATION_LOG}"
fi

# Record the -Dtarget=... value (if present) into a sibling log so tests can
# assert that the build script forwarded the target arch correctly. We only
# write the most recent value; tests that need history can inspect the main
# invocation log instead.
if [ -n "${STUB_ZIG_INVOCATION_LOG:-}" ]; then
  for arg in "$@"; do
    case "$arg" in
      -Dtarget=*)
        printf '%s\n' "${arg#-Dtarget=}" > "$(dirname "${STUB_ZIG_INVOCATION_LOG}")/stub-zig.target.log"
        ;;
    esac
  done
fi

# Parse --prefix; everything else ignored.
prefix=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --prefix=*) prefix="${1#--prefix=}"; shift ;;
    *) shift ;;
  esac
done
[ -n "${prefix}" ] || { echo "stub-zig: --prefix required" >&2; exit 1; }

# Stub xcframework: a minimal but plausible directory tree. The build script
# walks for Headers/module.modulemap, so we provide one. We embed a marker
# fingerprint so tests can confirm artifacts originated from THIS invocation
# vs. having been restored from a cache.
xcf="${PWD}/macos/GhosttyKit.xcframework"
slice="${xcf}/macos-arm64/GhosttyKit.framework"
mkdir -p "${slice}/Headers"
echo "stub-marker" > "${slice}/Headers/ghostty.h"
cat > "${slice}/Headers/module.modulemap" <<'EOF'
module Placeholder {}
EOF
cat > "${xcf}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>
EOF

mkdir -p "${prefix}/share/ghostty" "${prefix}/share/terminfo"
echo "stub-share-ghostty" > "${prefix}/share/ghostty/marker"
echo "stub-share-terminfo" > "${prefix}/share/terminfo/marker"

# Slow build simulation for concurrency tests.
if [ -n "${STUB_ZIG_SLEEP:-}" ]; then sleep "${STUB_ZIG_SLEEP}"; fi
