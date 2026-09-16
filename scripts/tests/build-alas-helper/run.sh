#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

srcroot="${sandbox}/repo"
mkdir -p "${srcroot}/scripts" "${srcroot}/AlasHelper/src" "${sandbox}/toolchain/bin"
cp "${repo_root}/scripts/build-alas-helper.sh" "${srcroot}/scripts/build-alas-helper.sh"
cp "${repo_root}/AlasHelper/Cargo.toml" "${srcroot}/AlasHelper/Cargo.toml"
cp "${repo_root}/AlasHelper/Cargo.lock" "${srcroot}/AlasHelper/Cargo.lock"
cp "${repo_root}/AlasHelper/manifest.json" "${srcroot}/AlasHelper/manifest.json"
cp "${repo_root}/AlasHelper/rust-toolchain.toml" "${srcroot}/AlasHelper/rust-toolchain.toml"
cp "${repo_root}/AlasHelper/src/main.rs" "${srcroot}/AlasHelper/src/main.rs"

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
printf '#!/bin/sh\n' > "\${target_dir}/\${target}/release/alas-helper"
chmod +x "\${target_dir}/\${target}/release/alas-helper"
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
        bash "${srcroot}/scripts/build-alas-helper.sh"
}

run_build

for target in \
    x86_64-unknown-linux-musl \
    aarch64-unknown-linux-musl \
    x86_64-apple-darwin \
    aarch64-apple-darwin; do
    grep -q -- "--target ${target}" "${invocations}"
    test -x "${srcroot}/.build/alas-helper/${target}/release/alas-helper"
done
test -f "${srcroot}/.build/alas-helper/fingerprint"

invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"

# Xcode passes an absolute script path while CI prebuild invokes it relatively.
(
    cd "${srcroot}"
    SRCROOT="${srcroot}" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        ALAS_CARGO_BIN="${sandbox}/cargo" \
        bash scripts/build-alas-helper.sh
)
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"

# A checkout at a different path with the same content reuses its artifacts.
srcroot2="${sandbox}/identical-helper-checkout"
cp -R "${srcroot}" "${srcroot2}"
(
    cd "${srcroot2}"
    SRCROOT="${srcroot2}" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        ALAS_CARGO_BIN="${sandbox}/cargo" \
        bash scripts/build-alas-helper.sh
)
test "$(wc -l < "${invocations}" | tr -d ' ')" = "${invocation_count}"
test "$(cat "${srcroot2}/.build/alas-helper/fingerprint")" = "$(cat "${srcroot}/.build/alas-helper/fingerprint")"

# The selected toolchain changes the compiled output and invalidates the cache.
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
ALAS_RUST_TOOLCHAIN="test-toolchain" run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

# Relevant source changes must invalidate a matching artifact cache.
run_build
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
printf '\n// fingerprint regression input\n' >> "${srcroot}/AlasHelper/src/main.rs"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

# A matching fingerprint is insufficient when an expected output is absent.
invocation_count="$(wc -l < "${invocations}" | tr -d ' ')"
rm "${srcroot}/.build/alas-helper/aarch64-apple-darwin/release/alas-helper"
run_build
test "$(wc -l < "${invocations}" | tr -d ' ')" -gt "${invocation_count}"

echo "build-alas-helper tests passed"
