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
rustup_bin="${ALAS_RUSTUP_BIN:-rustup}"
rust_toolchain="${ALAS_RUST_TOOLCHAIN:-1.97.1}"

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
fingerprint_path="${build_root}/fingerprint"

die() {
    echo "build-fff.sh: error: $*" >&2
    exit 1
}

# Fingerprint over the fff submodule (HEAD + working-tree dirt), target
# arch, Rust toolchain, and this script's content hash. A stale `.build/fff`
# from a previous submodule checkout or toolchain is invalidated.
fff_sha="$(git -C "${fff_src}" rev-parse HEAD 2>/dev/null || echo "")"
fff_dirt="$(
    {
        git -C "${fff_src}" diff --no-ext-diff --no-color HEAD -- . 2>/dev/null | shasum -a 256
        while IFS= read -r -d '' untracked; do
            printf '%s\0' "${untracked}"
            shasum -a 256 "${fff_src}/${untracked}" 2>/dev/null | awk '{print $1}'
        done < <(git -C "${fff_src}" ls-files --others --exclude-standard -z 2>/dev/null | LC_ALL=C sort -z) \
            | shasum -a 256
    } | shasum -a 256 | awk '{print $1}'
)"
script_id="$(shasum -a 256 "${script_path}" 2>/dev/null | awk '{print $1}')"
fingerprint="$(printf '%s\n%s\n%s\n%s\n%s\n' "${fff_sha}" "${fff_dirt}" "${target_arch}" "${rust_toolchain}" "${script_id}" | shasum -a 256 | awk '{print $1}')"

# Fast path: if the expected dylib for this arch already exists AND the
# fingerprint matches, skip the cargo build. The Xcode build phase runs
# this script on every build (`alwaysOutOfDate = 1`), but a cargo build
# from scratch takes ~40s, so reusing a previously produced dylib keeps
# incremental Xcode builds fast. The fingerprint pins the dylib to a
# specific submodule SHA + script version so a checkout change forces a
# rebuild rather than linking a stale artifact.
#
# The shared include dir (fff.h, module.modulemap) is also required — a
# partial clean that removed the headers while leaving the dylib would
# otherwise make the Swift compile fail with a missing header on a fast
# path that skipped regenerating it.
if [ -f "${lib_output}" ] \
   && [ -f "${fingerprint_path}" ] \
   && [ -f "${include_root}/fff.h" ] \
   && [ -f "${include_root}/module.modulemap" ] \
   && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ]; then
    echo "build-fff.sh: fast path — ${lib_output} up to date (fingerprint ${fingerprint:0:12})"
    exit 0
fi

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
    printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
    echo "build-fff.sh: produced universal ${lib_output}"
    exit 0
fi

[ -d "${fff_src}/.git" ] || [ -f "${fff_src}/.git" ] || die "submodule missing: ${fff_src}"
command -v "${rustup_bin}" >/dev/null 2>&1 || die "rustup not found"

case "${target_arch}" in
    arm64) cargo_target="aarch64-apple-darwin" ;;
    x86_64) cargo_target="x86_64-apple-darwin" ;;
    *) die "unsupported target_arch '${target_arch}'" ;;
esac

mkdir -p "${lib_dir}" "${include_root}"

"${rustup_bin}" toolchain install "${rust_toolchain}" --profile minimal
installed_targets="$("${rustup_bin}" target list --installed --toolchain "${rust_toolchain}")"
if ! printf '%s\n' "${installed_targets}" | grep -qx "${cargo_target}"; then
    "${rustup_bin}" target add --toolchain "${rust_toolchain}" "${cargo_target}"
fi

rustc_bin="$("${rustup_bin}" which --toolchain "${rust_toolchain}" rustc)"
if [ -n "${ALAS_CARGO_BIN:-}" ]; then
    cargo_bin="${ALAS_CARGO_BIN}"
else
    cargo_bin="$("${rustup_bin}" which --toolchain "${rust_toolchain}" cargo)"
fi

(
    cd "${fff_src}"
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
        RUSTC="${rustc_bin}" "${cargo_bin}" build \
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

# Write the fingerprint last so a partial interruption (between dylib
# install and header copy, or a failed header/modulemap write) leaves
# an absent or mismatched fingerprint rather than a stale-valid one.
printf '%s\n' "${fingerprint}" > "${fingerprint_path}"

echo "build-fff.sh: built ${lib_output}"
