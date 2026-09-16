#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

srcroot="${sandbox}/repo"
mkdir -p "${srcroot}/scripts" "${srcroot}/AlasCLI/crates/alas/src" "${srcroot}/AlasCLI/crates/alas-client/src" "${sandbox}/toolchain/bin"
cp "${repo_root}/scripts/build-alas-cli.sh" "${srcroot}/scripts/build-alas-cli.sh"
cp "${repo_root}/AlasCLI/Cargo.toml" "${srcroot}/AlasCLI/Cargo.toml"
cp "${repo_root}/AlasCLI/Cargo.lock" "${srcroot}/AlasCLI/Cargo.lock"
cp "${repo_root}/AlasCLI/manifest.json" "${srcroot}/AlasCLI/manifest.json"
cp "${repo_root}/AlasCLI/rust-toolchain.toml" "${srcroot}/AlasCLI/rust-toolchain.toml"
cp "${repo_root}/AlasCLI/crates/alas/Cargo.toml" "${srcroot}/AlasCLI/crates/alas/Cargo.toml"
cp "${repo_root}/AlasCLI/crates/alas-client/Cargo.toml" "${srcroot}/AlasCLI/crates/alas-client/Cargo.toml"
find "${repo_root}/AlasCLI/crates/alas/src" -type f -exec cp {} "${srcroot}/AlasCLI/crates/alas/src" \;
find "${repo_root}/AlasCLI/crates/alas-client/src" -type f -exec cp {} "${srcroot}/AlasCLI/crates/alas-client/src" \;

invocations="${sandbox}/invocations"
: > "${invocations}"

cat > "${sandbox}/rustup" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "rustup \$*" >> "${invocations}"
case "\$1 \$2" in
    "toolchain install") exit 0 ;;
    "target list") exit 0 ;;
    "target add") exit 0 ;;
    "which --toolchain")
        if [ "\${4:-}" = "rustc" ]; then
            echo "${sandbox}/toolchain/bin/rustc"
        else
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
EOF

cat > "${sandbox}/toolchain/bin/rustc" <<'EOF'
#!/usr/bin/env bash
echo 'host: aarch64-apple-darwin'
EOF
mkdir -p "${sandbox}/toolchain/lib/rustlib/aarch64-apple-darwin/bin"
cat > "${sandbox}/toolchain/lib/rustlib/aarch64-apple-darwin/bin/rust-lld" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${sandbox}/cargo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "cargo \$*" >> "${invocations}"
target=""
target_dir=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --target) target="\$2"; shift 2 ;;
        --target-dir) target_dir="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "\${target}" ] && [ -n "\${target_dir}" ]
mkdir -p "\${target_dir}/\${target}/release"
printf '#!/bin/sh\n' > "\${target_dir}/\${target}/release/alas"
chmod +x "\${target_dir}/\${target}/release/alas"
EOF

chmod +x \
    "${sandbox}/rustup" \
    "${sandbox}/cargo" \
    "${sandbox}/toolchain/bin/rustc" \
    "${sandbox}/toolchain/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"

run_build() {
    SRCROOT="${srcroot}" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        ALAS_CARGO_BIN="${sandbox}/cargo" \
        bash "${srcroot}/scripts/build-alas-cli.sh"
}

run_build

for target in \
    x86_64-apple-darwin \
    aarch64-apple-darwin; do
    grep -q -- "--target ${target}" "${invocations}"
    test -x "${srcroot}/.build/alas-cli/${target}/release/alas"
done
test -f "${srcroot}/.build/alas-cli/fingerprint"

invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"

# Xcode passes an absolute script path while CI prebuild invokes it relatively.
(
    cd "${srcroot}"
    SRCROOT="${srcroot}" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        ALAS_CARGO_BIN="${sandbox}/cargo" \
        bash scripts/build-alas-cli.sh
)
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"

# A checkout at a different path with the same content reuses its artifacts.
srcroot2="${sandbox}/identical-cli-checkout"
cp -R "${srcroot}" "${srcroot2}"
(
    cd "${srcroot2}"
    SRCROOT="${srcroot2}" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        ALAS_CARGO_BIN="${sandbox}/cargo" \
        bash scripts/build-alas-cli.sh
)
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"
test "$(cat "${srcroot2}/.build/alas-cli/fingerprint")" = "$(cat "${srcroot}/.build/alas-cli/fingerprint")"

# The selected toolchain changes the compiled output and invalidates the cache.
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
ALAS_RUST_TOOLCHAIN="test-toolchain" run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

# Relevant source changes must invalidate a matching artifact cache.
run_build
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
printf '\n// fingerprint regression input\n' >> "${srcroot}/AlasCLI/crates/alas/src/main.rs"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

# A matching fingerprint is insufficient when an expected output is absent.
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
rm "${srcroot}/.build/alas-cli/aarch64-apple-darwin/release/alas"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

echo "build-alas-cli tests passed"
