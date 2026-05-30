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

output="$("${repo_root}/scripts/prune-xcode-state.sh" --derived-data "${derived_data}")"

for expected in \
    "delete	"*Alas-stale \
    "delete	"*Ghostty-stale
do
    case "${output}" in
        *${expected}*) ;;
        *) echo "dry-run output did not list expected stale entry pattern: ${expected}"; echo "${output}"; exit 1 ;;
    esac
done

case "${output}" in
    *missing-workspace*) ;;
    *) echo "dry-run output did not include expected stale reasons"; echo "${output}"; exit 1 ;;
esac

case "${output}" in
    *"skip	"*missing-info-plist*Alas-missing-info*) ;;
    *) echo "dry-run output should skip missing plist entries"; echo "${output}"; exit 1 ;;
esac

case "${output}" in
    *"skip	"*unreadable-info-plist*Alas-unreadable-info*) ;;
    *) echo "dry-run output should skip unreadable plist entries"; echo "${output}"; exit 1 ;;
esac

case "${output}" in
    *Alas-live*) echo "dry-run output should not list live workspace"; echo "${output}"; exit 1 ;;
esac
case "${output}" in
    *Other-stale*) echo "dry-run output should not list unrelated entries"; echo "${output}"; exit 1 ;;
esac

[ -d "${derived_data}/Alas-stale" ] || { echo "dry-run removed Alas-stale"; exit 1; }
[ -d "${derived_data}/Ghostty-stale" ] || { echo "dry-run removed Ghostty-stale"; exit 1; }
[ -d "${derived_data}/Alas-missing-info" ] || { echo "dry-run removed Alas-missing-info"; exit 1; }
[ -d "${derived_data}/Alas-unreadable-info" ] || { echo "dry-run removed Alas-unreadable-info"; exit 1; }
