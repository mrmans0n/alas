#!/usr/bin/env bash
set -euo pipefail

# Builds and packages the headless host for Linux, on Linux, for the machine's
# own architecture: alas-host/alas-host beside RemoteWeb/, zmx/zmx and
# alas-cli/alas, the layout of the macOS alas-host zip, which is where the
# host looks for its web client, zmx and the alas CLI, plus VERSION, which it
# reports and updates itself by.
#
# The host links the Swift runtime statically; it still needs glibc, libcurl,
# libsqlite3 and zlib from the system. Build it on the oldest distribution it
# should run on (the release uses Ubuntu 22.04). zmx is a static musl binary.
# Used by .github/workflows/release.yml.
#
# Needs: swift, cargo (rustup) and a C linker (cc), and zig (ALAS_ZIG_BIN, default `zig`) with
# network access to fetch zmx's Zig packages.
#
# Usage: scripts/package-alas-host-linux.sh <version> <output-dir>
# Output: <output-dir>/alas-host-<version>-linux-<x86_64|aarch64>.tar.gz

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <version> <output-dir>" >&2
  exit 2
fi

version="$1"
out_dir="$(mkdir -p "$2" && cd "$2" && pwd)"
root="$(cd "$(dirname "$0")/.." && pwd)"
arch="$(uname -m)"
case "$arch" in
  x86_64 | aarch64) ;;
  arm64) arch=aarch64 ;;
  *)
    echo "error: unsupported architecture $arch" >&2
    exit 1
    ;;
esac
zig_bin="${ALAS_ZIG_BIN:-zig}"
build="$root/.build/linux-package/$arch"
mkdir -p "$build"

# The host, with the Swift runtime inside so the server needs no toolchain.
# Two jobs: the largest sources need several GB each to compile.
swift build -c release -j 2 --package-path "$root/Packages/AlasCore" --product alas-host --static-swift-stdlib
host="$(swift build -c release --package-path "$root/Packages/AlasCore" --show-bin-path)/alas-host"

# zmx, static against musl, as the app bundles it for SSH hosts.
(
  cd "$root/ThirdParty/zmx"
  ZIG_GLOBAL_CACHE_DIR="$build/zig-global-cache" "$zig_bin" build \
    -Doptimize=ReleaseFast -Dtarget="$arch-linux-musl" \
    --prefix "$build/zmx" --cache-dir "$build/zig-cache"
)

# The alas CLI agents call to reach the host.
# From its folder, so rustup picks its rust-toolchain.toml.
(cd "$root/AlasCLI" && cargo build --release --locked -p alas --target-dir "$build/cargo")

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/alas-host" "$stage/zmx" "$stage/alas-cli"
install -m 755 "$host" "$stage/alas-host/alas-host"
install -m 755 "$build/zmx/bin/zmx" "$stage/zmx/zmx"
install -m 755 "$build/cargo/release/alas" "$stage/alas-cli/alas"
cp -R "$root/Alas/Resources/RemoteWeb" "$stage/RemoteWeb"
# What the host reports as its version, and how its self-update finds its install.
printf '%s\n' "$version" > "$stage/VERSION"

archive="$out_dir/alas-host-$version-linux-$arch.tar.gz"
tar -C "$stage" -czf "$archive" VERSION alas-host RemoteWeb zmx alas-cli
echo "Wrote $archive"
