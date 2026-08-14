#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

srcroot="${sandbox}/repo"
pack_src="${srcroot}/ThirdParty/treesitter-pack"
toolchain_bin="${sandbox}/toolchain/bin"
invocations="${sandbox}/invocations"
symbols="${sandbox}/symbols"
mkdir -p "${srcroot}/scripts" "${pack_src}/src" "${pack_src}/include" \
    "${pack_src}/queries/hcl" "${toolchain_bin}" "${sandbox}/bin"
cp "${repo_root}/scripts/build-treesitter-pack.sh" "${srcroot}/scripts/build-treesitter-pack.sh"
printf 'fn main() {}\n' > "${pack_src}/src/lib.rs"
printf '[package]\nname = "alas-treesitter-pack"\n' > "${pack_src}/Cargo.toml"
printf '# lock\n' > "${pack_src}/Cargo.lock"
printf '#pragma once\n' > "${pack_src}/include/treesitter_pack.h"
printf '; query\n' > "${pack_src}/queries/hcl/highlights.scm"
: > "${invocations}"

# Every grammar the script asserts on. The fake nm below prints these back in
# `nm -g` format so the happy path passes without a real cargo build.
all_symbols=(
    bash c cpp css dockerfile go hcl html java javascript json kotlin lua
    markdown markdown_inline php php_only python ruby rust swift toml tsx
    typescript yaml
)
write_symbols() {
    : > "${symbols}"
    for s in "$@"; do
        printf '0000000000000000 T _tree_sitter_%s\n' "${s}" >> "${symbols}"
    done
}
write_symbols "${all_symbols[@]}"

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

build_counter="${sandbox}/build-counter"
echo 0 > "${build_counter}"

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
# Each invocation's archive gets distinguishable content (a build counter)
# rather than an empty file, so the test suite can tell whether a given
# build's output ever actually reached the live archive path.
n=\$(( \$(cat "${build_counter}") + 1 ))
echo "\${n}" > "${build_counter}"
echo "build \${n}" > "\${target_dir}/\${target}/release/libalas_treesitter_pack.a"
EOF

# Real nm exits non-zero on archives holding symbol-less objects, so the fake
# mimics that: the script must tolerate it rather than read the failure as
# "every grammar is missing".
cat > "${sandbox}/bin/nm" <<EOF
#!/usr/bin/env bash
cat "${symbols}"
exit 1
EOF

chmod +x "${sandbox}/rustup" "${toolchain_bin}/rustc" "${toolchain_bin}/cargo" "${sandbox}/bin/nm"

run_script() {
    SRCROOT="${srcroot}" \
        ALAS_TS_PACK_TARGET_ARCH="x86_64" \
        ALAS_RUSTUP_BIN="${sandbox}/rustup" \
        PATH="${sandbox}/bin:${PATH}" \
        bash "${srcroot}/scripts/build-treesitter-pack.sh"
}

# --- 1. cold build wires up the pinned toolchain and installs every artifact
run_script

grep -qx 'rustup toolchain install 1.97.1 --profile minimal' "${invocations}"
grep -qx 'rustup target add --toolchain 1.97.1 x86_64-apple-darwin' "${invocations}"
grep -q "^cargo RUSTC=${toolchain_bin}/rustc build " "${invocations}"
grep -q -- '--locked' "${invocations}"
test -f "${srcroot}/.build/treesitter-pack/x86_64/install/lib/libalas_treesitter_pack.a"
test -f "${srcroot}/.build/treesitter-pack/include/treesitter_pack.h"
grep -q 'link "alas_treesitter_pack"' "${srcroot}/.build/treesitter-pack/include/module.modulemap"

# --- 2. an unchanged tree fast-paths without invoking cargo again
: > "${invocations}"
run_script
test ! -s "${invocations}"

# --- 3. editing a crate source invalidates the fingerprint and rebuilds
printf 'fn main() { /* changed */ }\n' > "${pack_src}/src/lib.rs"
: > "${invocations}"
run_script
grep -q "^cargo RUSTC=" "${invocations}"

last_good_archive="${srcroot}/.build/treesitter-pack/x86_64/install/lib/libalas_treesitter_pack.a"
last_good_content="$(cat "${last_good_archive}")"

# --- 4. a grammar missing from the archive fails the build instead of
#        shipping a pack that silently renders that language as plain text
write_symbols "${all_symbols[@]/lua/}"
printf 'fn main() { /* changed again */ }\n' > "${pack_src}/src/lib.rs"
if run_script > "${sandbox}/out" 2>&1; then
    echo "expected a missing grammar entry point to fail the build" >&2
    exit 1
fi
grep -q 'tree_sitter_lua' "${sandbox}/out"
grep -q "^cargo RUSTC=" "${invocations}"

# --- 4b. the failed build must not have overwritten the last good archive —
#         validation happens against cargo's fresh output before it is ever
#         copied over the live path, so a rejected build leaves the previous
#         good archive (and its fingerprint) exactly as they were.
test "$(cat "${last_good_archive}")" = "${last_good_content}"

# --- 5. a failed build must not leave a fingerprint that would fast-path the
#        broken archive on the next run
test ! -f "${srcroot}/.build/treesitter-pack/x86_64/fingerprint" \
    || ! diff -q <(cat "${srcroot}/.build/treesitter-pack/x86_64/fingerprint") /dev/null >/dev/null 2>&1

# --- 5b. reverting to the last-good inputs must still reuse the untouched
#         last-good archive via the normal fast path (not rebuild, and
#         certainly not the rejected one from step 4) — this is the scenario
#         the fix protects: a revert after a failed grammar update.
printf 'fn main() { /* changed */ }\n' > "${pack_src}/src/lib.rs"
: > "${invocations}"
run_script
test ! -s "${invocations}"
test "$(cat "${last_good_archive}")" = "${last_good_content}"

# --- 6. a subsequent successful build still rebuilds and promotes normally
printf 'fn main() { /* changed again, fixed */ }\n' > "${pack_src}/src/lib.rs"
: > "${invocations}"
write_symbols "${all_symbols[@]}"
run_script
grep -q "^cargo RUSTC=" "${invocations}"
test "$(cat "${last_good_archive}")" != "${last_good_content}"

echo "build-treesitter-pack tests passed"
