#!/bin/sh
# Installs the headless Alas host on a Linux server, for the current user:
# unpacks the release tarball into ~/.local/opt/alas-host, links alas-host
# into ~/.local/bin and starts it as a systemd user service. Rerunning it
# upgrades in place. No root needed, except to enable lingering if your
# system asks for it.
#
#   curl -fsSL https://github.com/mrmans0n/alas/releases/latest/download/install-alas-host.sh | sh
#
# ALAS_HOST_VERSION=<version> installs that release instead of the latest.
# ALAS_HOST_TARBALL=<path> installs a tarball you already have.
set -eu

repo=https://github.com/mrmans0n/alas
root="$HOME/.local/opt/alas-host"
bin="$HOME/.local/bin"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "this installs alas-host on Linux; on a Mac use 'brew install --cask mrmans0n/tap/alas-host'"
arch="$(uname -m)"
case "$arch" in
  x86_64 | aarch64) ;;
  arm64) arch=aarch64 ;;
  *) fail "unsupported architecture $arch" ;;
esac

for tool in curl tar git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is missing"
done
# ldconfig lives in sbin, which a user's PATH often leaves out. Without it,
# skip the check rather than report libraries missing that may be there.
libs="$(PATH="$PATH:/usr/sbin:/sbin" ldconfig -p 2>/dev/null || true)"
missing=""
if [ -n "$libs" ]; then
  for lib in libcurl.so.4 libsqlite3.so.0 libz.so.1; do
    echo "$libs" | grep -q "$lib" || missing="$missing $lib"
  done
fi
[ -z "$missing" ] || fail "missing$missing; on Debian or Ubuntu: sudo apt install libcurl4 libsqlite3-0 zlib1g"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ -n "${ALAS_HOST_TARBALL:-}" ]; then
  cp "$ALAS_HOST_TARBALL" "$work/host.tar.gz"
else
  version="${ALAS_HOST_VERSION:-}"
  if [ -z "$version" ]; then
    # /releases/latest redirects to /releases/tag/v<version>.
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$repo/releases/latest")"
    version="${latest##*/v}"
  fi
  echo "Downloading alas-host $version for $arch"
  curl -fSL --progress-bar -o "$work/host.tar.gz" \
    "$repo/releases/download/v$version/alas-host-$version-linux-$arch.tar.gz" \
    || fail "release v$version has no alas-host for linux-$arch"
fi

# Unpack beside the install, then swap it in, so a failed download or
# extract leaves the current install alone.
mkdir -p "$(dirname "$root")" "$bin"
staged="$root.new"
rm -rf "$staged"
mkdir -p "$staged"
tar -xzf "$work/host.tar.gz" -C "$staged"
[ -x "$staged/alas-host/alas-host" ] || fail "the tarball has no alas-host/alas-host"
rm -rf "$root.old"
upgrade=""
[ ! -e "$root" ] || { mv "$root" "$root.old"; upgrade=1; }
mv "$staged" "$root"
rm -rf "$root.old"
ln -sfn "$root/alas-host/alas-host" "$bin/alas-host"
echo "Installed alas-host $(cat "$root/VERSION") in $root"

"$root/alas-host/alas-host" install-agent
# install-agent leaves a running host alone; an upgrade has to replace it.
[ -z "$upgrade" ] || "$root/alas-host/alas-host" restart
# Keeps the service running while you are logged out.
loginctl enable-linger "$(id -un)" 2>/dev/null \
  || echo "note: run 'sudo loginctl enable-linger $(id -un)' to keep alas-host running while you are logged out"

case ":$PATH:" in
  *":$bin:"*) host="alas-host" ;;
  *) host="$bin/alas-host" ; echo "note: $bin is not on your PATH" ;;
esac
# A new host serves nobody until Remote is reachable; settings it already
# has are left alone.
if [ "$("$root/alas-host/alas-host" config get host.reachability 2>/dev/null)" = off ]; then
  echo "Done. Remote is off: run '$host setup' to choose how your Mac reaches this server and pair it,"
  echo "or '$host config set host.reachability tailscale --restart' (or lan), then '$host pair'."
  echo "To use Alas in a browser on this machine, set it to loopback instead and open the link '$host pair' prints."
else
  echo "Done. Run '$host pair' for a link to pair this server from Alas on your Mac."
fi
