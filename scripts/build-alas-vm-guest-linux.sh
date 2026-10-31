#!/usr/bin/env bash
set -euo pipefail

if [ -n "${HOME:-}" ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${PATH}"
else
    export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
workspace_root="${srcroot}/AlasCLI"
crate_root="${workspace_root}/crates/alas-vm-guest-linux"
build_root="${srcroot}/.build/alas-vm-guest-linux"
fingerprint_path="${build_root}/fingerprint"
rustup_bin="${ALAS_RUSTUP_BIN:-rustup}"
# The AlasCLI workspace's toolchain, as in build-alas-cli.sh.
rust_toolchain="${ALAS_RUST_TOOLCHAIN:-1.97.0}"
zig_bin="${ALAS_ZIG_BIN:-$(command -v zig || true)}"

# Linux worktree VMs are arm64 only.
targets=(
    aarch64-unknown-linux-musl
)

die() {
    echo "build-alas-vm-guest-linux.sh: error: $*" >&2
    exit 1
}

command -v "${rustup_bin}" >/dev/null 2>&1 || die "rustup not found"
[ -f "${workspace_root}/Cargo.lock" ] || die "missing ${workspace_root}/Cargo.lock"
[ -x "${zig_bin}" ] || die "Zig is required as the C compiler for Linux musl"

fingerprint="$({
    (
        cd "${crate_root}"
        find . -type f -print0 \
            | LC_ALL=C sort -z \
            | xargs -0 shasum -a 256
    )
    # The workspace manifest holds the release profile, edition and version.
    shasum -a 256 < "${workspace_root}/Cargo.toml"
    shasum -a 256 < "${workspace_root}/Cargo.lock"
    shasum -a 256 < "${script_dir}/build-alas-vm-guest-linux.sh"
    printf 'rust_toolchain=%s\n' "${rust_toolchain}"
    printf 'zig_bin=%s\n' "${zig_bin}"
    "${zig_bin}" version
    shasum -a 256 "${zig_bin}"
    printf 'target=%s\n' "${targets[@]}"
} | shasum -a 256 | awk '{print $1}')"

outputs_present=1
for target in "${targets[@]}"; do
    [ -x "${build_root}/${target}/release/alas-vm-guest-linux" ] || outputs_present=0
done
if [ "${outputs_present}" = "1" ] \
   && [ -f "${fingerprint_path}" ] \
   && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ]; then
    exit 0
fi

"${rustup_bin}" toolchain install "${rust_toolchain}" --profile minimal
installed_targets="$(${rustup_bin} target list --installed --toolchain "${rust_toolchain}")"
for target in "${targets[@]}"; do
    if ! printf '%s\n' "${installed_targets}" | grep -qx "${target}"; then
        "${rustup_bin}" target add --toolchain "${rust_toolchain}" "${target}"
    fi
done

rustc_bin="$(${rustup_bin} which --toolchain "${rust_toolchain}" rustc)"
if [ -n "${ALAS_CARGO_BIN:-}" ]; then
    cargo_bin="${ALAS_CARGO_BIN}"
else
    cargo_bin="$(${rustup_bin} which --toolchain "${rust_toolchain}" cargo)"
fi
host_target="$("${rustc_bin}" -vV | awk '/^host:/ { print $2 }')"
rust_lld="$(dirname "${rustc_bin}")/../lib/rustlib/${host_target}/bin/rust-lld"
[ -x "${rust_lld}" ] || die "Rust toolchain did not provide rust-lld"
mkdir -p "${build_root}/toolchain"
ln -sf "${rust_lld}" "${build_root}/toolchain/ld.lld"

for target in "${targets[@]}"; do
    rustflags=()
    build_env=("RUSTC=${rustc_bin}")
    case "${target}" in
        *-unknown-linux-musl)
            # The crate has no C code today; the Zig wrappers keep cc-rs working if it ever does.
            rustflags=(-C "linker=${build_root}/toolchain/ld.lld" -C linker-flavor=ld)
            zig_target="${target/-unknown-linux-musl/-linux-musl}"
            cc_wrapper="${build_root}/toolchain/cc-${target}"
            printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "${zig_bin}" "${zig_target}" > "${cc_wrapper}"
            chmod +x "${cc_wrapper}"
            ar_wrapper="${build_root}/toolchain/ar-${target}"
            printf '#!/bin/sh\nexec "%s" ar "$@"\n' "${zig_bin}" > "${ar_wrapper}"
            chmod +x "${ar_wrapper}"
            # cc-rs otherwise supplies a Rust-style --target that Zig rejects.
            # The wrapper owns the target; retain optimization/PIC explicitly.
            build_env+=("CC_${target//-/_}=${cc_wrapper}" "AR_${target//-/_}=${ar_wrapper}" "CRATE_CC_NO_DEFAULTS=1" "CFLAGS_${target//-/_}=-O3 -fPIC")
            ;;
    esac
    if [ "${#rustflags[@]}" -gt 0 ]; then
        encoded_rustflags="${rustflags[0]}"
        for flag in "${rustflags[@]:1}"; do
            encoded_rustflags+=$'\037'"${flag}"
        done
        build_env+=("CARGO_ENCODED_RUSTFLAGS=${encoded_rustflags}")
    fi
    env "${build_env[@]}" "${cargo_bin}" build \
        --locked \
        --release \
        --manifest-path "${workspace_root}/Cargo.toml" \
        --package alas-vm-guest-linux \
        --target "${target}" \
        --target-dir "${build_root}"
    output="${build_root}/${target}/release/alas-vm-guest-linux"
    [ -x "${output}" ] || die "cargo did not produce ${output}"
done

printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
echo "build-alas-vm-guest-linux.sh: built ${#targets[@]} targets"
