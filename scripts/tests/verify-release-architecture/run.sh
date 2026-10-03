#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d -t verify-release-architecture.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

fake_bin="${tmp}/bin"
app="${tmp}/Alas.app"
mkdir -p "${fake_bin}" \
    "${app}/Contents/MacOS" \
    "${app}/Contents/Resources/zmx" \
    "${app}/Contents/Frameworks"

cat > "${fake_bin}/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "-archs" ]
cat "$2"
EOF
chmod +x "${fake_bin}/lipo"

write_arches() {
    printf '%s\n' "$2" > "$1"
}

write_arches "${app}/Contents/MacOS/Alas" "arm64"
write_arches "${app}/Contents/Resources/zmx/zmx" "arm64"
write_arches "${app}/Contents/Frameworks/libfff_c.dylib" "arm64"
write_arches "${app}/Contents/Frameworks/libswiftCompatibilitySpan.dylib" "x86_64 arm64 arm64e"
write_arches "${app}/Contents/Frameworks/libthirdparty.dylib" "arm64"

PATH="${fake_bin}:${PATH}" \
    "${repo_root}/scripts/verify-release-architecture.sh" "${app}" arm64

write_arches "${app}/Contents/Frameworks/libthirdparty.dylib" "x86_64 arm64"
if PATH="${fake_bin}:${PATH}" \
    "${repo_root}/scripts/verify-release-architecture.sh" "${app}" arm64 \
    >"${tmp}/unexpected-universal.out" 2>&1; then
    echo "accepted a universal app-owned dylib" >&2
    exit 1
fi
grep -Fq "libthirdparty.dylib has architectures 'x86_64 arm64'; expected exactly 'arm64'" \
    "${tmp}/unexpected-universal.out"

write_arches "${app}/Contents/Frameworks/libthirdparty.dylib" "arm64"
write_arches "${app}/Contents/Frameworks/libswiftCompatibilitySpan.dylib" "x86_64 arm64e"
if PATH="${fake_bin}:${PATH}" \
    "${repo_root}/scripts/verify-release-architecture.sh" "${app}" arm64 \
    >"${tmp}/missing-compatibility-arch.out" 2>&1; then
    echo "accepted a Swift compatibility dylib without the release architecture" >&2
    exit 1
fi
grep -Fq "libswiftCompatibilitySpan.dylib has architectures 'x86_64 arm64e'; expected to contain 'arm64'" \
    "${tmp}/missing-compatibility-arch.out"

echo "verify-release-architecture tests: ok"
