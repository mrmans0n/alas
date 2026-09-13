#!/bin/zsh
# alas-name: Build
# alas-on-exit: close

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
derived_data="${repo_root}/.build/xcode/DerivedData"
app_path="${derived_data}/Build/Products/Debug/Alas.app"

cd "$repo_root"

xcodegen
xcodebuild \
    -project Alas.xcodeproj \
    -scheme Alas \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build

open -n "$app_path"
