#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

srcroot="${tmp}/srcroot"
mkdir -p "${srcroot}/ThirdParty/zmx"
(cd "${srcroot}/ThirdParty/zmx" && git init -q && git commit -q --allow-empty -m init)

# A zig stub that records each build invocation, so we can count them.
counter="${tmp}/build-count"
echo 0 > "${counter}"
cat > "${tmp}/counting-zig.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" != "build" ]; then
    echo "counting-zig: unsupported subcommand: \${1:-}" >&2
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
mkdir -p "\${prefix}/bin"
printf '#!/bin/sh\necho stub\n' > "\${prefix}/bin/zmx"
chmod +x "\${prefix}/bin/zmx"
n=\$(cat "${counter}")
echo \$((n + 1)) > "${counter}"
EOF
chmod +x "${tmp}/counting-zig.sh"

env_vars=(
    "SRCROOT=${srcroot}"
    "ALAS_ZMX_TARGET_ARCH=arm64"
    "ALAS_ZIG_BIN=${tmp}/counting-zig.sh"
    "ALAS_ZMX_CACHE_DIR=${tmp}/cache"
)
env "${env_vars[@]}" bash "${repo_root}/scripts/build-zmx.sh"
first=$(cat "${counter}")
[ "${first}" = "3" ] || { echo "expected 3 total Zig invocations on cold cache, got ${first}" >&2; exit 1; }

env "${env_vars[@]}" bash "${repo_root}/scripts/build-zmx.sh"
second=$(cat "${counter}")
[ "${second}" = "3" ] || { echo "expected cache hit (still 3 total Zig invocations), got ${second}" >&2; exit 1; }
