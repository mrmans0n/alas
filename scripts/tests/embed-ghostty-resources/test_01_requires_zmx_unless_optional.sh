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
    "${resources}"

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
    SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZMX_OPTIONAL="1" \
    bash "${repo_root}/scripts/embed-ghostty-resources.sh" >"${tmp}/optional.out" 2>"${tmp}/optional.err"
grep -q "warning: zmx binary not found" "${tmp}/optional.err" || {
    echo "missing optional-mode warning" >&2
    cat "${tmp}/optional.err" >&2
    exit 1
}
