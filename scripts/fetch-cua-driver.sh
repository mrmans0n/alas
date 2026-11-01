#!/usr/bin/env bash
# Fetches the pinned Cua Driver (trycua/cua) glibc arm64 Linux build that a
# Linux worktree VM's guest helper runs for computer use, verifies it, and
# leaves only the `cua-driver` executable and its licence notice in
# .build/cua-driver/<version>/. .build/cua-driver/current names that version;
# it is a plain file, not a symlink, so CI's cache globs never follow it.
#
# Never the musl build: the SDK compiles no Linux platform tools for musl.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

version="0.38.1-nightly.20261101.41272696578"
release_tag="nightly-cua-driver-rs-v${version}"
source_commit="8db684185a93e854bb7811189d69f933bb15f55d"
asset="cua-driver-rs-${version}-linux-arm64-binary.tar.gz"
asset_sha256="1a402d78d1fcaefac7f4bd2ba0535ee0293f28c799ab7956795f47b9e8a5f8ce"
url="https://github.com/trycua/cua/releases/download/${release_tag}/${asset}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
build_root="${srcroot}/.build/cua-driver"
output_dir="${build_root}/${version}"
fingerprint_path="${build_root}/fingerprint"

die() {
    echo "fetch-cua-driver.sh: error: $*" >&2
    exit 1
}

# The script holds the version and checksum, so its hash is the whole input.
fingerprint="$(shasum -a 256 < "${script_dir}/fetch-cua-driver.sh" | awk '{print $1}')"

if [ -x "${output_dir}/cua-driver" ] \
   && [ -f "${output_dir}/CUA-DRIVER-LICENSE.txt" ] \
   && [ "$(cat "${build_root}/current" 2>/dev/null || true)" = "${version}" ] \
   && [ -f "${fingerprint_path}" ] \
   && [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ]; then
    exit 0
fi

mkdir -p "${build_root}"
work_dir="$(mktemp -d "${build_root}/download.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

curl -fL --retry 3 --silent --show-error -o "${work_dir}/${asset}" "${url}" \
    || die "could not download ${url}; Cua Driver is needed for the Linux VM guest (network required on first build)"
actual_sha256="$(shasum -a 256 < "${work_dir}/${asset}" | awk '{print $1}')"
[ "${actual_sha256}" = "${asset_sha256}" ] \
    || die "${asset} has SHA256 ${actual_sha256}, expected ${asset_sha256}"

mkdir -p "${work_dir}/extract"
tar -xzf "${work_dir}/${asset}" -C "${work_dir}/extract" cua-driver
[ -f "${work_dir}/extract/cua-driver" ] || die "${asset} has no cua-driver"

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
install -m 0755 "${work_dir}/extract/cua-driver" "${output_dir}/cua-driver"

cat > "${output_dir}/CUA-DRIVER-LICENSE.txt" <<EOF
Cua Driver ${version} (${url}), built from trycua/cua commit ${source_commit}.

MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Third-party notices (libs/cua-driver/rust/THIRD_PARTY_NOTICES.md)

Parts of Cua Driver are derived from, or embed, these MIT-licensed projects,
under the MIT License text above:

- trope-cua (https://github.com/voctory/trope-cua):
  Copyright (c) 2026 Victor Vannara
- Interface-Agent (https://github.com/francedot/Interface-Agent):
  Copyright (c) 2024 Francesco Bonacci
- yabai (https://github.com/koekeishiya/yabai):
  Copyright (c) 2019 Åsmund Vikane
- QuickJS-ng (https://github.com/quickjs-ng/quickjs):
  Copyright (c) 2017-2026 Fabrice Bellard; (c) 2017-2024 Charlie Gordon;
  (c) 2023-2026 Ben Noordhuis; (c) 2023-2026 Saúl Ibarra Corretgé
- rquickjs (https://github.com/DelSkayn/rquickjs):
  Copyright (c) 2020 Mees Delzenne; (c) 2025 Rquickjs Contributors
- T3 Code (https://github.com/pingdotgg/t3code):
  Copyright (c) 2026 T3 Tools Inc.
EOF

printf '%s\n' "${version}" > "${build_root}/current"
# Drop earlier pins so the tools cache only carries this one.
find "${build_root}" -mindepth 1 -maxdepth 1 -type d ! -name "${version}" ! -path "${work_dir}" -exec rm -rf {} +
printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
echo "fetch-cua-driver.sh: fetched Cua Driver ${version}"
