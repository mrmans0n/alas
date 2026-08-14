#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

srcroot="${tmp}/srcroot"
mkdir -p "${srcroot}/ThirdParty/zmx"
(cd "${srcroot}/ThirdParty/zmx" && git init -q && git commit -q --allow-empty -m init)

counter="${tmp}/build-count"
echo 0 > "${counter}"
cat > "${tmp}/missing-output-zig.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" != "build" ]; then
    echo "missing-output-zig: unsupported subcommand: \${1:-}" >&2
    exit 2
fi
shift
prefix=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --prefix) prefix="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
n=\$(cat "${counter}")
n=\$((n + 1))
echo "\${n}" > "${counter}"
if [ "\${n}" -lt 3 ]; then
    echo "missing-output-zig: simulated success without output" >&2
    exit 0
fi
mkdir -p "\${prefix}/bin"
printf '#!/bin/sh\necho stub\n' > "\${prefix}/bin/zmx"
chmod +x "\${prefix}/bin/zmx"
EOF
chmod +x "${tmp}/missing-output-zig.sh"

SRCROOT="${srcroot}" \
ALAS_ZMX_TARGET_ARCH="arm64" \
ALAS_ZIG_BIN="${tmp}/missing-output-zig.sh" \
ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
ALAS_ZMX_RETRY_DELAYS="0 0" \
    bash "${repo_root}/scripts/build-zmx.sh" >"${tmp}/out" 2>"${tmp}/err"

[ "$(cat "${counter}")" = "5" ] || { echo "expected 5 total Zig invocations" >&2; exit 1; }
grep -q "retrying in 0s (attempt 2/3)" "${tmp}/err" || { echo "missing first retry warning" >&2; exit 1; }
grep -q "retrying in 0s (attempt 3/3)" "${tmp}/err" || { echo "missing second retry warning" >&2; exit 1; }
[ -x "${srcroot}/.build/zmx/arm64/install/bin/zmx" ] || { echo "missing zmx output after retry" >&2; exit 1; }
