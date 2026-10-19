#!/usr/bin/env bash
# Builds the headless `alas-host` executable from Packages/AlasCore for the
# app's architecture, for embed-ghostty-resources.sh to copy into the bundle.
# Release app builds get an optimized binary; every other configuration a
# debug one, which builds in a fraction of the time. Skipped when nothing it
# depends on changed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
package_root="${srcroot}/Packages/AlasCore"

if [ -z "${ALAS_HOST_TARGET_ARCH:-}" ] && [ "${CURRENT_ARCH:-}" = "undefined_arch" ]; then
    case "${ARCHS:-}" in
        arm64|x86_64) target_arch="${ARCHS}" ;;
        *) target_arch="universal" ;;
    esac
else
    target_arch="${ALAS_HOST_TARGET_ARCH:-${CURRENT_ARCH:-$(uname -m)}}"
fi
case "${target_arch}" in
    arm64|x86_64) arch_flags=(--arch "${target_arch}") ;;
    universal) arch_flags=(--arch arm64 --arch x86_64) ;;
    *) echo "build-alas-host.sh: error: unsupported architecture ${target_arch}" >&2; exit 1 ;;
esac
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    swift_configuration=release
else
    swift_configuration=debug
fi

output_root="${srcroot}/.build/alas-host/${target_arch}"
output="${output_root}/alas-host"
fingerprint_path="${output_root}/fingerprint"
scratch_path="${srcroot}/.build/alas-host/scratch-${swift_configuration}-${target_arch}"

# Xcode's build settings are exported to this script; SwiftPM must not see
# them, or it builds against the app target's settings instead of its own.
clean_env=(/usr/bin/env -i "HOME=${HOME}" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "TMPDIR=${TMPDIR:-/tmp}")
if [ -n "${DEVELOPER_DIR:-}" ]; then
    clean_env+=("DEVELOPER_DIR=${DEVELOPER_DIR}")
fi

fingerprint="$({
    (
        cd "${package_root}"
        find . -path ./.build -prune -o -type f -print0 \
            | LC_ALL=C sort -z \
            | xargs -0 shasum -a 256
    )
    shasum -a 256 < "${script_dir}/build-alas-host.sh"
    "${clean_env[@]}" xcrun swift --version 2>&1
    printf 'configuration=%s\narch=%s\n' "${swift_configuration}" "${target_arch}"
} | shasum -a 256 | awk '{print $1}')"

if [ -x "${output}" ] && [ -f "${fingerprint_path}" ] && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ]; then
    exit 0
fi

# Invalidated first, so an interrupted build is never taken as current.
rm -f "${fingerprint_path}"
build=("${clean_env[@]}" xcrun swift build
    --package-path "${package_root}"
    --scratch-path "${scratch_path}"
    --configuration "${swift_configuration}"
    "${arch_flags[@]}"
    --product alas-host)
"${build[@]}"
bin_path="$("${build[@]}" --show-bin-path)"
[ -x "${bin_path}/alas-host" ] || { echo "build-alas-host.sh: error: swift build did not produce ${bin_path}/alas-host" >&2; exit 1; }

mkdir -p "${output_root}"
cp "${bin_path}/alas-host" "${output}.tmp"
mv -f "${output}.tmp" "${output}"
printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
echo "build-alas-host.sh: built alas-host (${swift_configuration}, ${target_arch})"
