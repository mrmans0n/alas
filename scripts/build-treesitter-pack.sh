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
# Resolved once so the fingerprint and the actual cargo invocation below
# can't drift apart by each applying the `:-15.0` default independently.
macos_deployment_target="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

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
# queries, header), target arch, Rust toolchain, effective deployment
# target, and this script. Unlike the submodule-backed tools, this crate is
# tracked in-repo, so hashing its files directly is both simpler and
# stricter than a git SHA — an uncommitted edit to lib.rs invalidates the
# artifact too. Paths are relativized so the same content fingerprints
# identically across worktrees. MACOSX_DEPLOYMENT_TARGET is included
# because it's passed to cargo below and directly affects the compiled C
# objects' minimum OS target — an archive cached under one value must not
# be reused after that value changes.
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
fingerprint="$(printf '%s\n%s\n%s\n%s\n%s\n' "${pack_id}" "${target_arch}" "${rust_toolchain}" "${macos_deployment_target}" "${script_id}" | shasum -a 256 | awk '{print $1}')"

# The installed header/modulemap live in a *shared* location — the header is
# genuinely arch-independent C, so publishing per-arch copies would just be
# duplication — but that sharing means the per-arch fast path above can't
# validate them by existence alone. If x86_64 is built, then arm64 is built
# after a header change (overwriting the shared copy), then the tree is
# reverted and x86_64 is built again, x86_64's own fingerprint legitimately
# matches its last build, but the shared header on disk is still arm64's
# newer one. This tracks which pack_id + script the *installed* header
# actually corresponds to, independent of arch/toolchain/deployment target
# (none of which affect header content), so any arch's fast path can detect
# a header that was last published by a different pack revision.
header_fingerprint_path="${include_root}/fingerprint"
header_fingerprint="$(printf '%s\n%s\n' "${pack_id}" "${script_id}" | shasum -a 256 | awk '{print $1}')"

# Fast path: Xcode runs this phase on every build, but a cold cargo build of
# 25 grammars takes minutes. Reuse the previous archive when the fingerprint
# still matches. The header and modulemap are part of the check so a partial
# clean that removed them can't leave the Swift compile without a module;
# header_fingerprint_path additionally guards against the shared-header
# cross-contamination described above.
if [ -f "${lib_output}" ] \
   && [ -f "${fingerprint_path}" ] \
   && [ -f "${include_root}/treesitter_pack.h" ] \
   && [ -f "${include_root}/module.modulemap" ] \
   && [ -f "${header_fingerprint_path}" ] \
   && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ] \
   && [ "$(cat "${header_fingerprint_path}")" = "${header_fingerprint}" ]; then
    echo "build-treesitter-pack.sh: fast path — ${lib_output} up to date (fingerprint ${fingerprint:0:12})"
    exit 0
fi

install_headers() {
    mkdir -p "${include_root}"
    rsync -a --checksum "${pack_src}/include/treesitter_pack.h" "${include_root}/treesitter_pack.h"
    cat > "${include_root}/module.modulemap" <<'MODULEMAP'
module TreeSitterPack [system] {
    header "treesitter_pack.h"
    link "alas_treesitter_pack"
    export *
}
MODULEMAP
    # Written last, matching the archive fingerprint's own ordering: this
    # marker exists only once both files it describes are fully installed.
    printf '%s\n' "${header_fingerprint}" > "${header_fingerprint_path}"
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

    # Same ordering fix as the per-arch path below: clear the recorded
    # fingerprint before lipo starts overwriting the live universal archive.
    # Each slice is already validated by its own recursive per-arch
    # invocation above, but an interruption or install_headers failure
    # between lipo and the fingerprint write here would otherwise leave a
    # newly promoted archive paired with the *previous* universal build's
    # stale fingerprint.
    rm -f "${fingerprint_path}"
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
    MACOSX_DEPLOYMENT_TARGET="${macos_deployment_target}" \
        RUSTC="${rustc_bin}" "${cargo_bin}" build \
            --release \
            --locked \
            --target "${cargo_target}" \
            --target-dir "${build_root}/cargo-target"
)

cargo_output="${build_root}/cargo-target/${cargo_target}/release/libalas_treesitter_pack.a"
[ -f "${cargo_output}" ] || die "cargo did not produce ${cargo_output}"

# Guard against a silently partial link surface: every grammar entry point the
# Swift registry can ask for must be *defined* in the archive. A grammar crate
# that stops being pulled into the link graph would otherwise only surface as a
# missing symbol at app link time, or worse, as silently unhighlighted text.
#
# This runs against `cargo_output` — the freshly built archive still outside
# `lib_output` — rather than against `lib_output` after copying it there.
# Validating in place would mean a failed guard leaves a broken archive at the
# live path while `fingerprint_path` still holds the *previous* good
# fingerprint (only written on success below). If the inputs were then
# reverted to that previous state, the fast path would match on the stale
# fingerprint and reuse the broken archive without ever re-running `nm`. By
# validating before anything touches `lib_output`, a failed build always
# leaves the last good archive and fingerprint untouched.
#
# nm exits non-zero on archives that contain symbol-less objects, so its
# output is captured to a file rather than piped — under `pipefail` a pipe
# would report every symbol as missing regardless of what grep found.
symbol_dump="${build_root}/symbols.txt"
nm -g "${cargo_output}" > "${symbol_dump}" 2>/dev/null || true
missing=""
for symbol in \
    bash c c_sharp clojure_orchard cmake cpp css dart dockerfile elixir \
    erlang go graphql groovy haskell hcl html ini java javascript json \
    julia kotlin lua make markdown markdown_inline objc php php_only \
    powershell proto python r ruby rust scala scss sql svelte swift toml \
    tsx typescript xml yaml zig
do
    if ! grep -qE " T _tree_sitter_${symbol}\$" "${symbol_dump}"; then
        missing="${missing} tree_sitter_${symbol}"
    fi
done
[ -z "${missing}" ] || die "archive is missing grammar entry points:${missing}"

# Clear the recorded fingerprint before promoting the validated archive. On a
# rebuild, `fingerprint_path` still holds the *previous* build's fingerprint
# at this point — an interruption (or an `install_headers` failure) between
# here and the fingerprint write below would otherwise leave that stale
# marker on disk pointing at content it no longer describes: the archive has
# already been promoted, but the recorded fingerprint still matches the
# old inputs. Reverting to those old inputs would then fast-path a mismatched
# archive. Removing the marker first means any interruption in this window
# leaves no fingerprint at all, forcing a full rebuild and revalidation next
# time instead of trusting a pairing that never happened.
rm -f "${fingerprint_path}"

# --checksum forces a content comparison instead of rsync's default
# size+mtime quick check, which can skip a copy it deems "unchanged" when a
# rebuild happens to produce same-size output within the same mtime tick — a
# real risk across fast, repeated local rebuilds, not just a test artifact.
rsync -a --checksum "${cargo_output}" "${lib_output}"
install_headers

# Written last so the fingerprint only ever exists once the archive and
# headers it describes are fully installed.
printf '%s\n' "${fingerprint}" > "${fingerprint_path}"

echo "build-treesitter-pack.sh: built ${lib_output}"
