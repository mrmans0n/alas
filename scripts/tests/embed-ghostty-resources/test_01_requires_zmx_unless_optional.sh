#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

srcroot="${tmp}/srcroot"
resources="${tmp}/build/Resources"
mkdir -p \
    "${srcroot}/.build/ghostty/share/ghostty" \
    "${srcroot}/.build/ghostty/share/terminfo" \
    "${srcroot}/.build/fff/arm64/install/lib" \
    "${srcroot}/AlasHelper" \
    "${tmp}/bin" \
    "${resources}"

for target in \
    x86_64-unknown-linux-musl \
    aarch64-unknown-linux-musl \
    x86_64-apple-darwin \
    aarch64-apple-darwin; do
    helper="${srcroot}/.build/alas-helper/${target}/release/alas-helper"
    mkdir -p "$(dirname "${helper}")"
    printf '#!/bin/sh\n' > "${helper}"
    chmod +x "${helper}"
done
cp "${repo_root}/AlasHelper/manifest.json" "${srcroot}/AlasHelper/manifest.json"
touch "${srcroot}/.build/fff/arm64/install/lib/libfff_c.dylib"
for tool in install_name_tool codesign; do
    printf '#!/bin/sh\nexit 0\n' > "${tmp}/bin/${tool}"
    chmod +x "${tmp}/bin/${tool}"
done

if TARGET_BUILD_DIR="${tmp}/build" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
    SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    bash "${repo_root}/scripts/embed-ghostty-resources.sh" >"${tmp}/required.out" 2>"${tmp}/required.err"; then
    echo "expected missing zmx to fail without ALAS_ZMX_OPTIONAL=1" >&2
    exit 1
fi
grep -q "error: zmx binary not found" "${tmp}/required.err" || {
    echo "missing required-mode error" >&2
    cat "${tmp}/required.err" >&2
    exit 1
}

TARGET_BUILD_DIR="${tmp}/build" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
    FRAMEWORKS_FOLDER_PATH="Frameworks" \
    SRCROOT="${srcroot}" \
    ALAS_FFF_TARGET_ARCH="arm64" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZMX_OPTIONAL="1" \
    PATH="${tmp}/bin:${PATH}" \
    bash "${repo_root}/scripts/embed-ghostty-resources.sh" >"${tmp}/optional.out" 2>"${tmp}/optional.err"
grep -q "warning: zmx binary not found" "${tmp}/optional.err" || {
    echo "missing optional-mode warning" >&2
    cat "${tmp}/optional.err" >&2
    exit 1
}
test -x "${resources}/alas-helper/linux-x86_64/alas-helper"
test -x "${resources}/alas-helper/linux-aarch64/alas-helper"
test -x "${resources}/alas-helper/macos-x86_64/alas-helper"
test -x "${resources}/alas-helper/macos-aarch64/alas-helper"
cmp "${srcroot}/AlasHelper/manifest.json" "${resources}/alas-helper/manifest.json"

# Stale-bundle cleanup: a previously bundled zmx in TARGET_BUILD_DIR must be
# removed on an optional skip so the app does not silently ship a stale
# helper after a developer toggles ALAS_ZMX_OPTIONAL=1.
mkdir -p "${resources}/zmx"
printf '#!/bin/sh\necho stale\n' > "${resources}/zmx/zmx"
chmod +x "${resources}/zmx/zmx"

TARGET_BUILD_DIR="${tmp}/build" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
    FRAMEWORKS_FOLDER_PATH="Frameworks" \
    SRCROOT="${srcroot}" \
    ALAS_FFF_TARGET_ARCH="arm64" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZMX_OPTIONAL="1" \
    PATH="${tmp}/bin:${PATH}" \
    bash "${repo_root}/scripts/embed-ghostty-resources.sh" >"${tmp}/optional-stale.out" 2>"${tmp}/optional-stale.err"
if [ -e "${resources}/zmx/zmx" ]; then
    echo "stale bundled zmx was not removed on optional skip" >&2
    ls -l "${resources}/zmx/zmx" >&2
    exit 1
fi
