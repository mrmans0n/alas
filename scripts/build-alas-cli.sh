#!/usr/bin/env bash
set -euo pipefail

if [ -n "${HOME:-}" ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.cargo/bin:${PATH}"
else
    export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
cli_root="${srcroot}/AlasCLI"
build_root="${srcroot}/.build/alas-cli"
fingerprint_path="${build_root}/fingerprint"
rustup_bin="${ALAS_RUSTUP_BIN:-rustup}"
rust_toolchain="${ALAS_RUST_TOOLCHAIN:-1.97.0}"

targets=(
    x86_64-apple-darwin
    aarch64-apple-darwin
)

die() {
    echo "build-alas-cli.sh: error: $*" >&2
    exit 1
}

command -v "${rustup_bin}" >/dev/null 2>&1 || die "rustup not found"
[ -f "${cli_root}/Cargo.lock" ] || die "missing ${cli_root}/Cargo.lock"

fingerprint="$({
    find "${cli_root}" -path "${cli_root}/target" -prune -o -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256
    shasum -a 256 "${BASH_SOURCE[0]}"
} | shasum -a 256 | awk '{print $1}')"

outputs_present=1
for target in "${targets[@]}"; do
    [ -x "${build_root}/${target}/release/alas" ] || outputs_present=0
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

for target in "${targets[@]}"; do
    env "RUSTC=${rustc_bin}" "${cargo_bin}" build \
        --locked \
        --release \
        --bin alas \
        --manifest-path "${cli_root}/Cargo.toml" \
        --target "${target}" \
        --target-dir "${build_root}"
    output="${build_root}/${target}/release/alas"
    [ -x "${output}" ] || die "cargo did not produce ${output}"
done

printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
echo "build-alas-cli.sh: built ${#targets[@]} targets"
