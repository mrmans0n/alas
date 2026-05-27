#!/usr/bin/env bash
set -euo pipefail
this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Build a fake SRCROOT with a fake git submodule.
srcroot="${tmp}/srcroot"
mkdir -p "${srcroot}/ThirdParty/zmx"
(cd "${srcroot}/ThirdParty/zmx" && git init -q && git commit -q --allow-empty -m init)

SRCROOT="${srcroot}" \
ALAS_ZMX_TARGET_ARCH="arm64" \
ALAS_ZIG_BIN="${this_dir}/fixtures/stub-zig.sh" \
ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    bash "${repo_root}/scripts/build-zmx.sh"

out="${srcroot}/.build/zmx/arm64/install/bin/zmx"
[ -x "${out}" ] || { echo "missing or non-executable output: ${out}" >&2; exit 1; }
