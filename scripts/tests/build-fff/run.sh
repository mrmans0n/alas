#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

srcroot="${sandbox}/repo"
fff_src="${srcroot}/ThirdParty/fff"
toolchain_bin="${sandbox}/toolchain/bin"
invocations="${sandbox}/invocations"
mkdir -p "${srcroot}/scripts" "${fff_src}/crates/fff-c/include" "${toolchain_bin}" "${sandbox}/bin"
cp "${repo_root}/scripts/build-fff.sh" "${srcroot}/scripts/build-fff.sh"
printf '#pragma once\n' > "${fff_src}/crates/fff-c/include/fff.h"
: > "${invocations}"

git -C "${fff_src}" init -q
git -C "${fff_src}" add .
git -C "${fff_src}" -c user.name=test -c user.email=test@example.com commit -qm initial

cat > "${sandbox}/rustup" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "rustup \$*" >> "${invocations}"
case "\$1 \$2" in
    "toolchain install") exit 0 ;;
    "target list") exit 0 ;;
    "target add") exit 0 ;;
    "which --toolchain")
        case "\${4:-}" in
            rustc) echo "${toolchain_bin}/rustc" ;;
            cargo) echo "${toolchain_bin}/cargo" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF

cat > "${toolchain_bin}/rustc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${toolchain_bin}/cargo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "cargo RUSTC=\${RUSTC:-} \$*" >> "${invocations}"
target=""
target_dir=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --target) target="\$2"; shift 2 ;;
        --target-dir) target_dir="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "\${target_dir}/\${target}/release"
touch "\${target_dir}/\${target}/release/libfff_c.dylib"
EOF

cat > "${sandbox}/bin/install_name_tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${sandbox}/rustup" "${toolchain_bin}/rustc" "${toolchain_bin}/cargo" "${sandbox}/bin/install_name_tool"

SRCROOT="${srcroot}" \
    ALAS_FFF_TARGET_ARCH="x86_64" \
    ALAS_RUSTUP_BIN="${sandbox}/rustup" \
    PATH="${sandbox}/bin:${PATH}" \
    bash "${srcroot}/scripts/build-fff.sh"

grep -qx 'rustup toolchain install 1.97.1 --profile minimal' "${invocations}"
grep -qx 'rustup target list --installed --toolchain 1.97.1' "${invocations}"
grep -qx 'rustup target add --toolchain 1.97.1 x86_64-apple-darwin' "${invocations}"
grep -qx 'rustup which --toolchain 1.97.1 rustc' "${invocations}"
grep -qx 'rustup which --toolchain 1.97.1 cargo' "${invocations}"
grep -q "^cargo RUSTC=${toolchain_bin}/rustc build " "${invocations}"
test -f "${srcroot}/.build/fff/x86_64/install/lib/libfff_c.dylib"

: > "${invocations}"
SRCROOT="${srcroot}" \
    ALAS_FFF_TARGET_ARCH="x86_64" \
    ALAS_RUST_TOOLCHAIN="1.98.0" \
    ALAS_RUSTUP_BIN="${sandbox}/rustup" \
    PATH="${sandbox}/bin:${PATH}" \
    bash "${srcroot}/scripts/build-fff.sh"

grep -qx 'rustup toolchain install 1.98.0 --profile minimal' "${invocations}"
grep -q "^cargo RUSTC=${toolchain_bin}/rustc build " "${invocations}"

echo "build-fff tests passed"
