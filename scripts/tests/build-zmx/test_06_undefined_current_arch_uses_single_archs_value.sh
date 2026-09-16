#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

srcroot="${tmp}/srcroot"
mkdir -p "${srcroot}/ThirdParty/zmx"
(cd "${srcroot}/ThirdParty/zmx" && git init -q && git commit -q --allow-empty -m init)

SRCROOT="${srcroot}" \
CURRENT_ARCH="undefined_arch" \
ARCHS="arm64" \
ALAS_ZIG_BIN="${this_dir}/fixtures/stub-zig.sh" \
ALAS_ZMX_CACHE_DIR="${tmp}/cache" \
    bash "${repo_root}/scripts/build-zmx.sh"

test -x "${srcroot}/.build/zmx/arm64/install/bin/zmx"
test ! -e "${srcroot}/.build/zmx/universal/install/bin/zmx"
test ! -e "${srcroot}/.build/zmx/x86_64/install/bin/zmx"
