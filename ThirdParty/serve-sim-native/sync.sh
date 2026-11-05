#!/usr/bin/env bash
# Re-vendors serve-sim's native Swift from expo/expo-device-hub at one commit.
# Copies StreamingPolicy and CoreDeviceShim whole, and the SimNative files
# listed in vendored-files.txt. AlasSimulatorSession.swift is ours and is
# left alone.
set -euo pipefail

commit="${1:?usage: sync.sh <expo-device-hub commit>}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone -q --filter=blob:none --no-checkout --sparse \
  https://github.com/expo/expo-device-hub.git "$work/repo"
git -C "$work/repo" sparse-checkout set --no-cone \
  '/packages/serve-sim/packages/serve-sim/Sources/' \
  '/packages/serve-sim/LICENSE' \
  '/packages/serve-sim/NOTICE'
git -C "$work/repo" checkout -q "$commit"

src="$work/repo/packages/serve-sim/packages/serve-sim/Sources"
mkdir -p "$here/Sources/ServeSimCore"
rm -rf "$here/Sources/StreamingPolicy" "$here/Sources/CoreDeviceShim"
cp -R "$src/StreamingPolicy" "$src/CoreDeviceShim" "$here/Sources/"
while read -r name; do
  [ -n "$name" ] || continue
  cp "$src/SimNative/$name.swift" "$here/Sources/ServeSimCore/$name.swift"
done < "$here/vendored-files.txt"
cp "$work/repo/packages/serve-sim/LICENSE" "$work/repo/packages/serve-sim/NOTICE" "$here/"
ruby "$here/patches/apply-core-device-shim-x86_64.rb"
printf '%s\n' "$commit" > "$here/UPSTREAM_COMMIT"
echo "Vendored serve-sim native code at $commit"
