#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/serve-sim-native-release.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

shim_dir="${repo_root}/ThirdParty/serve-sim-native/Sources/CoreDeviceShim"
assembly="${shim_dir}/CoreDeviceTrampolines.S"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
c_sources=(
  CoreDeviceMotionShim.c
  CoreDeviceHingeReadbackShim.c
  CoreDeviceStateReadbackShim.c
)

for arch in arm64 x86_64; do
  xcrun --sdk macosx clang \
    -arch "${arch}" \
    -isysroot "${sdk}" \
    -mmacosx-version-min=15.0 \
    -x assembler-with-cpp \
    -c "${assembly}" \
    -o "${tmp}/CoreDeviceTrampolines-${arch}.o"

  for source in "${c_sources[@]}"; do
    xcrun --sdk macosx clang \
      -arch "${arch}" \
      -isysroot "${sdk}" \
      -mmacosx-version-min=15.0 \
      -fblocks \
      -I "${shim_dir}/include" \
      -c "${shim_dir}/${source}" \
      -o "${tmp}/${source%.c}-${arch}.o"
  done
done

ruby -e '
  shim_dir = ARGV.fetch(0)
  assembly = File.read(File.join(shim_dir, "CoreDeviceTrampolines.S"))
  raise "async descriptors must not use cross-object subtraction relocations" if
    assembly.match?(/\.long _SSCD(?:MotionManager|HingeReadback|DeviceStateReadback|OrientationReadback) -/)

  expected = {
    "CoreDeviceMotionShim.c" => [["SSCDMotionManagerDescriptor", "SSCDMotionManager"]],
    "CoreDeviceHingeReadbackShim.c" => [["SSCDHingeReadbackDescriptor", "SSCDHingeReadback"]],
    "CoreDeviceStateReadbackShim.c" => [
      ["SSCDDeviceStateReadbackDescriptor", "SSCDDeviceStateReadback"],
      ["SSCDOrientationReadbackDescriptor", "SSCDOrientationReadback"]
    ]
  }
  expected.each do |file, pairs|
    text = File.read(File.join(shim_dir, file))
    pairs.each do |descriptor, entry|
      pattern = /intptr_t entryOffset = \(intptr_t\)&#{entry} - \(intptr_t\)#{descriptor};\s*if \(entryOffset < INT32_MIN \|\| entryOffset > INT32_MAX\) return;\s*#{descriptor}\[0\] = \(int32_t\)entryOffset;/
      raise "#{file} must initialize and bounds-check #{descriptor}" unless text.match?(pattern)
    end
  end
' "${shim_dir}"

echo "serve-sim-native release assembly: ok"
