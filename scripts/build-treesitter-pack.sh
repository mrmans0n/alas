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
pack_src="${srcroot}/ThirdParty/treesitter-pack"
rustup_bin="${ALAS_RUSTUP_BIN:-rustup}"
rust_toolchain="${ALAS_RUST_TOOLCHAIN:-1.97.1}"

if [ -z "${ALAS_TS_PACK_TARGET_ARCH:-}" ] && [ "${CURRENT_ARCH:-}" = "undefined_arch" ]; then
    target_arch="universal"
else
    target_arch="${ALAS_TS_PACK_TARGET_ARCH:-${CURRENT_ARCH:-$(uname -m)}}"
fi

build_root="${srcroot}/.build/treesitter-pack/${target_arch}"
install_root="${build_root}/install"
lib_dir="${install_root}/lib"
lib_output="${lib_dir}/libalas_treesitter_pack.a"
include_root="${srcroot}/.build/treesitter-pack/include"
fingerprint_path="${build_root}/fingerprint"

die() {
    echo "build-treesitter-pack.sh: error: $*" >&2
    exit 1
}

[ -d "${pack_src}" ] || die "missing crate: ${pack_src}"

# Fingerprint over the crate's own inputs (manifest, lockfile, sources,
# queries, header), target arch, Rust toolchain, and this script. Unlike the
# submodule-backed tools, this crate is tracked in-repo, so hashing its files
# directly is both simpler and stricter than a git SHA — an uncommitted edit
# to lib.rs invalidates the artifact too. Paths are relativized so the same
# content fingerprints identically across worktrees.
pack_id="$(
    (
        cd "${pack_src}"
        find . -type f \
            \( -path './src/*' -o -path './queries/*' -o -path './include/*' \
               -o -name Cargo.toml -o -name Cargo.lock \) \
            -not -path './target/*' -print0 \
            | LC_ALL=C sort -z \
            | xargs -0 shasum -a 256
    ) | shasum -a 256 | awk '{print $1}'
)"
script_id="$(shasum -a 256 "${script_path}" 2>/dev/null | awk '{print $1}')"
fingerprint="$(printf '%s\n%s\n%s\n%s\n' "${pack_id}" "${target_arch}" "${rust_toolchain}" "${script_id}" | shasum -a 256 | awk '{print $1}')"

# Fast path: Xcode runs this phase on every build, but a cold cargo build of
# 25 grammars takes minutes. Reuse the previous archive when the fingerprint
# still matches. The header and modulemap are part of the check so a partial
# clean that removed them can't leave the Swift compile without a module.
if [ -f "${lib_output}" ] \
   && [ -f "${fingerprint_path}" ] \
   && [ -f "${include_root}/treesitter_pack.h" ] \
   && [ -f "${include_root}/module.modulemap" ] \
   && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ]; then
    echo "build-treesitter-pack.sh: fast path — ${lib_output} up to date (fingerprint ${fingerprint:0:12})"
    exit 0
fi

install_headers() {
    mkdir -p "${include_root}"
    rsync -a "${pack_src}/include/treesitter_pack.h" "${include_root}/treesitter_pack.h"
    cat > "${include_root}/module.modulemap" <<'MODULEMAP'
module TreeSitterPack [system] {
    header "treesitter_pack.h"
    link "alas_treesitter_pack"
    export *
}
MODULEMAP
}

if [ "${target_arch}" = "universal" ]; then
    mkdir -p "${lib_dir}"
    for slice in arm64 x86_64; do
        env ALAS_TS_PACK_TARGET_ARCH="${slice}" CURRENT_ARCH="" bash "${script_path}"
    done

    arm64_slice="${srcroot}/.build/treesitter-pack/arm64/install/lib/libalas_treesitter_pack.a"
    x86_64_slice="${srcroot}/.build/treesitter-pack/x86_64/install/lib/libalas_treesitter_pack.a"
    [ -f "${arm64_slice}" ] || die "missing arm64 archive at ${arm64_slice}"
    [ -f "${x86_64_slice}" ] || die "missing x86_64 archive at ${x86_64_slice}"

    lipo -create "${arm64_slice}" "${x86_64_slice}" -output "${lib_output}"
    install_headers
    printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
    echo "build-treesitter-pack.sh: produced universal ${lib_output}"
    exit 0
fi

command -v "${rustup_bin}" >/dev/null 2>&1 || die "rustup not found"

case "${target_arch}" in
    arm64) cargo_target="aarch64-apple-darwin" ;;
    x86_64) cargo_target="x86_64-apple-darwin" ;;
    *) die "unsupported target_arch '${target_arch}'" ;;
esac

mkdir -p "${lib_dir}"

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
    cd "${pack_src}"
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}" \
        RUSTC="${rustc_bin}" "${cargo_bin}" build \
            --release \
            --locked \
            --target "${cargo_target}" \
            --target-dir "${build_root}/cargo-target"
)

cargo_output="${build_root}/cargo-target/${cargo_target}/release/libalas_treesitter_pack.a"
[ -f "${cargo_output}" ] || die "cargo did not produce ${cargo_output}"

rsync -a "${cargo_output}" "${lib_output}"
install_headers

# Guard against a silently partial link surface: every grammar entry point the
# Swift registry can ask for must be *defined* in the archive. A grammar crate
# that stops being pulled into the link graph would otherwise only surface as a
# missing symbol at app link time, or worse, as silently unhighlighted text.
#
# nm exits non-zero on archives that contain symbol-less objects, so its
# output is captured to a file rather than piped — under `pipefail` a pipe
# would report every symbol as missing regardless of what grep found.
symbol_dump="${build_root}/symbols.txt"
nm -g "${lib_output}" > "${symbol_dump}" 2>/dev/null || true
missing=""
for symbol in \
    bash c cpp css dockerfile go hcl html java javascript json kotlin lua \
    markdown markdown_inline php php_only python ruby rust swift toml tsx \
    typescript yaml
do
    if ! grep -qE " T _tree_sitter_${symbol}\$" "${symbol_dump}"; then
        missing="${missing} tree_sitter_${symbol}"
    fi
done
[ -z "${missing}" ] || die "archive is missing grammar entry points:${missing}"

# Written last so an interruption between the archive copy and the header
# install leaves an absent fingerprint rather than a stale-valid one.
printf '%s\n' "${fingerprint}" > "${fingerprint_path}"

echo "build-treesitter-pack.sh: built ${lib_output}"
