#!/usr/bin/env bash
set -euo pipefail

# Packages the headless host from a signed, notarized Alas.app as a zip of
# its own, for the alas-host Homebrew cask: alas-host/alas-host beside
# RemoteWeb/ and zmx/zmx, the layout the host looks for its web client
# (../RemoteWeb) and zmx (../zmx/zmx) in. The binaries are copied
# unchanged, so they keep the signature the app's notarization covered.
# Used by .github/workflows/release.yml.
#
# Usage: scripts/package-alas-host.sh <app-path> <output-prefix>
# Output (next to the .app): <output-prefix>.zip

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <app-path> <output-prefix>" >&2
  exit 2
fi

app_path="$1"
prefix="$2"
resources="$app_path/Contents/Resources"
host="$resources/alas-host/alas-host"

if [ ! -x "$host" ]; then
  echo "error: $host is not an executable" >&2
  exit 1
fi
if [ ! -f "$resources/RemoteWeb/index.html" ]; then
  echo "error: $resources/RemoteWeb has no web client" >&2
  exit 1
fi
if [ ! -x "$resources/zmx/zmx" ]; then
  echo "error: $resources/zmx/zmx is not an executable" >&2
  exit 1
fi

out_dir="$(cd "$(dirname "$app_path")" && pwd)"
stage_dir="$(mktemp -d -t package-alas-host)"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/alas-host"
ditto "$host" "$stage_dir/alas-host/alas-host"
ditto "$resources/RemoteWeb" "$stage_dir/RemoteWeb"
ditto "$resources/zmx/zmx" "$stage_dir/zmx/zmx"

# All at the zip's root, where the cask's `binary` stanza finds the host.
rm -f "$out_dir/$prefix.zip"
ditto -c -k --norsrc --noextattr "$stage_dir" "$out_dir/$prefix.zip"
echo "Wrote $out_dir/$prefix.zip"
