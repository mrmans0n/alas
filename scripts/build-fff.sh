#!/usr/bin/env bash
set -euo pipefail

if [ -n "${HOME:-}" ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${PATH}"
else
    export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
fff_src="${srcroot}/ThirdParty/fff"

if [ -z "${ALAS_FFF_TARGET_ARCH:-}" ] && [ "${CURRENT_ARCH:-}" = "undefined_arch" ]; then
    target_arch="universal"
else
    target_arch="${ALAS_FFF_TARGET_ARCH:-${CURRENT_ARCH:-$(uname -m)}}"
fi

build_root="${srcroot}/.build/fff/${target_arch}"
install_root="${build_root}/install"
lib_dir="${install_root}/lib"
lib_output="${lib_dir}/libfff_c.dylib"
include_root="${srcroot}/.build/fff/include"

die() {
    echo "build-fff.sh: error: $*" >&2
    exit 1
}

if [ "${target_arch}" = "universal" ]; then
    mkdir -p "${lib_dir}"
    for slice in arm64 x86_64; do
        env ALAS_FFF_TARGET_ARCH="${slice}" CURRENT_ARCH="" bash "${script_path}"
    done

    arm64_slice="${srcroot}/.build/fff/arm64/install/lib/libfff_c.dylib"
    x86_64_slice="${srcroot}/.build/fff/x86_64/install/lib/libfff_c.dylib"
    [ -f "${arm64_slice}" ] || die "missing arm64 fff dylib at ${arm64_slice}"
    [ -f "${x86_64_slice}" ] || die "missing x86_64 fff dylib at ${x86_64_slice}"

    lipo -create "${arm64_slice}" "${x86_64_slice}" -output "${lib_output}"
    install_name_tool -id @rpath/libfff_c.dylib "${lib_output}"
    echo "build-fff.sh: produced universal ${lib_output}"
    exit 0
fi

[ -d "${fff_src}/.git" ] || [ -f "${fff_src}/.git" ] || die "submodule missing: ${fff_src}"
command -v cargo >/dev/null 2>&1 || die "cargo not found. Install Rust or ensure cargo is on PATH"

case "${target_arch}" in
    arm64) cargo_target="aarch64-apple-darwin" ;;
    x86_64) cargo_target="x86_64-apple-darwin" ;;
    *) die "unsupported target_arch '${target_arch}'" ;;
esac

mkdir -p "${lib_dir}" "${include_root}"

if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed | grep -qx "${cargo_target}"; then
        rustup target add "${cargo_target}"
    fi
fi

(
    cd "${fff_src}"
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
        cargo build \
            --package fff-c \
            --release \
            --target "${cargo_target}" \
            --target-dir "${build_root}/cargo-target"
)

cargo_output="${build_root}/cargo-target/${cargo_target}/release/libfff_c.dylib"
[ -f "${cargo_output}" ] || die "cargo did not produce ${cargo_output}"

rsync -a "${cargo_output}" "${lib_output}"
install_name_tool -id @rpath/libfff_c.dylib "${lib_output}"

rsync -a "${fff_src}/crates/fff-c/include/fff.h" "${include_root}/fff.h"
cat > "${include_root}/module.modulemap" <<'MODULEMAP'
module FffC [system] {
    header "fff.h"
    link "fff_c"
    export *
}
MODULEMAP

echo "build-fff.sh: built ${lib_output}"
