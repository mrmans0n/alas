#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d -t alas-xcode-state-test.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

derived_data="${tmp}/DerivedData"
live_workspace="${tmp}/live/Alas.xcodeproj"
mkdir -p "${derived_data}" "$(dirname "${live_workspace}")"
: > "${live_workspace}"

write_info_plist() {
    local dir="$1"
    local workspace="$2"
    mkdir -p "${dir}"
    cat > "${dir}/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WorkspacePath</key>
  <string>${workspace}</string>
</dict>
</plist>
EOF
}

write_info_plist "${derived_data}/Alas-live" "${live_workspace}"
write_info_plist "${derived_data}/Alas-stale" "${tmp}/missing/Alas.xcodeproj"
write_info_plist "${derived_data}/Ghostty-stale" "${tmp}/missing/Ghostty.xcodeproj"
mkdir -p "${derived_data}/Alas-missing-info"
mkdir -p "${derived_data}/Alas-unreadable-info"
printf 'not a plist\n' > "${derived_data}/Alas-unreadable-info/info.plist"
mkdir -p "${derived_data}/Other-stale"

"${repo_root}/scripts/prune-xcode-state.sh" --derived-data "${derived_data}" --delete >/tmp/alas-prune-test.out

[ -d "${derived_data}/Alas-live" ] || { echo "deleted live workspace"; exit 1; }
[ ! -e "${derived_data}/Alas-stale" ] || { echo "kept stale Alas entry"; exit 1; }
[ ! -e "${derived_data}/Ghostty-stale" ] || { echo "kept stale Ghostty entry"; exit 1; }
[ -d "${derived_data}/Alas-missing-info" ] || { echo "deleted missing-info Alas entry"; exit 1; }
[ -d "${derived_data}/Alas-unreadable-info" ] || { echo "deleted unreadable plist entry"; exit 1; }
[ -d "${derived_data}/Other-stale" ] || { echo "deleted unrelated entry"; exit 1; }
