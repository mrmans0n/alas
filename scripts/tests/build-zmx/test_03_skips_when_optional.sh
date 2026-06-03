#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

srcroot="${tmp}/srcroot"
mkdir -p "${srcroot}"

# Case 1: missing zig binary AND missing submodule -> required mode fails,
# ALAS_ZMX_OPTIONAL=1 downgrades to a warning and exits 0.
missing_zig="${tmp}/does-not-exist/zig"

if SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZIG_BIN="${missing_zig}" \
    ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/required.out" 2>"${tmp}/required.err"; then
    echo "expected missing zig to fail without ALAS_ZMX_OPTIONAL=1" >&2
    exit 1
fi
grep -q "error: zig not found" "${tmp}/required.err" || {
    echo "missing required-mode error for missing zig" >&2
    cat "${tmp}/required.err" >&2
    exit 1
}

SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZIG_BIN="${missing_zig}" \
    ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    ALAS_ZMX_OPTIONAL="1" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/optional.out" 2>"${tmp}/optional.err"
grep -q "warning: zig not found" "${tmp}/optional.err" || {
    echo "missing optional-mode warning for missing zig" >&2
    cat "${tmp}/optional.err" >&2
    exit 1
}
grep -q "skipping zmx build" "${tmp}/optional.err" || {
    echo "missing 'skipping zmx build' notice" >&2
    cat "${tmp}/optional.err" >&2
    exit 1
}

# Case 2: zig present (stub) but submodule missing -> required mode fails,
# optional mode skips.
stub_zig="${this_dir}/fixtures/stub-zig.sh"

if SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZIG_BIN="${stub_zig}" \
    ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/required2.out" 2>"${tmp}/required2.err"; then
    echo "expected missing submodule to fail without ALAS_ZMX_OPTIONAL=1" >&2
    exit 1
fi
grep -q "error: submodule missing" "${tmp}/required2.err" || {
    echo "missing required-mode error for missing submodule" >&2
    cat "${tmp}/required2.err" >&2
    exit 1
}

SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZIG_BIN="${stub_zig}" \
    ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    ALAS_ZMX_OPTIONAL="1" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/optional2.out" 2>"${tmp}/optional2.err"
grep -q "warning: submodule missing" "${tmp}/optional2.err" || {
    echo "missing optional-mode warning for missing submodule" >&2
    cat "${tmp}/optional2.err" >&2
    exit 1
}

# Case 3: stale per-arch zmx binary from a prior successful build is removed
# when the optional skip path fires, so embed-ghostty-resources.sh's -x
# check does not silently ship the stale helper.
stale_install="${srcroot}/.build/zmx/arm64/install/bin"
mkdir -p "${stale_install}"
printf '#!/bin/sh\necho stale\n' > "${stale_install}/zmx"
chmod +x "${stale_install}/zmx"

SRCROOT="${srcroot}" \
    ALAS_ZMX_TARGET_ARCH="arm64" \
    ALAS_ZIG_BIN="${missing_zig}" \
    ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    ALAS_ZMX_OPTIONAL="1" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/stale.out" 2>"${tmp}/stale.err"
if [ -e "${stale_install}/zmx" ]; then
    echo "stale zmx binary was not removed on optional skip" >&2
    ls -l "${stale_install}/zmx" >&2
    exit 1
fi
