#!/usr/bin/env bash
# Builds serve-sim's accessibility settings helper for the iOS simulator. It
# runs inside a simulator with `simctl spawn`, so it targets the simulator SDK
# for both Mac architectures. Without that SDK the helper is left out and the
# app reports it missing.
set -euo pipefail

srcroot="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source_file="${srcroot}/ThirdParty/serve-sim-native/Sources/SimAXSettings/sim-ax-settings.m"
out_dir="${srcroot}/.build/sim-ax-settings"
output="${out_dir}/alas-sim-ax-settings"
stamp="${out_dir}/fingerprint"

if ! sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"; then
    rm -rf "${out_dir}"
    echo "build-sim-ax-settings.sh: warning: no iOS Simulator SDK; simulator accessibility settings are unavailable" >&2
    exit 0
fi

fingerprint="$(cat "${source_file}" "$0" | shasum -a 256 | cut -d' ' -f1) ${sdk}"
if [ -x "${output}" ] && [ "$(cat "${stamp}" 2>/dev/null)" = "${fingerprint}" ]; then
    exit 0
fi

mkdir -p "${out_dir}"
xcrun --sdk iphonesimulator clang \
    -arch arm64 -arch x86_64 \
    -mios-simulator-version-min=15.0 \
    -isysroot "${sdk}" \
    -framework CoreFoundation \
    -o "${output}" \
    "${source_file}"
printf '%s' "${fingerprint}" > "${stamp}"
