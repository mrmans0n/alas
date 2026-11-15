#!/usr/bin/env bash
# Fetches the pinned scrcpy-server (Genymobile/scrcpy), the jar Alas pushes to
# an Android device to stream its screen, and scrcpy's Apache-2.0 licence into
# .build/scrcpy/, checking both against pinned SHA-256s.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

version="5.0.1"
server_sha256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
license_sha256="01c12035bf35af37241298dc7ad538eb2a07e5c940437bc6876feeaa9d1951d0"
server_url="https://github.com/Genymobile/scrcpy/releases/download/v${version}/scrcpy-server-v${version}"
license_url="https://raw.githubusercontent.com/Genymobile/scrcpy/v${version}/LICENSE"

srcroot="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
out_dir="${srcroot}/.build/scrcpy"

die() {
    echo "fetch-scrcpy-server.sh: error: $*" >&2
    exit 1
}

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

if [ "$(sha "${out_dir}/scrcpy-server")" = "${server_sha256}" ] && [ "$(sha "${out_dir}/LICENSE")" = "${license_sha256}" ]; then
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 -o "${tmp}/scrcpy-server" "${server_url}" || die "couldn't download ${server_url}"
curl -fsSL --retry 3 -o "${tmp}/LICENSE" "${license_url}" || die "couldn't download ${license_url}"
[ "$(sha "${tmp}/scrcpy-server")" = "${server_sha256}" ] || die "scrcpy-server doesn't match its pinned SHA-256"
[ "$(sha "${tmp}/LICENSE")" = "${license_sha256}" ] || die "scrcpy's LICENSE doesn't match its pinned SHA-256"
mkdir -p "${out_dir}"
mv "${tmp}/scrcpy-server" "${tmp}/LICENSE" "${out_dir}/"
