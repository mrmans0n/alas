#!/usr/bin/env bash
set -euo pipefail

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

# Ghostty + terminfo (existing).
ghostty_source="${SRCROOT}/.build/ghostty/share/ghostty"
terminfo_source="${SRCROOT}/.build/ghostty/share/terminfo"
ghostty_destination="${destination_root}/ghostty"
terminfo_destination="${destination_root}/terminfo"

rm -rf "${ghostty_destination}" "${terminfo_destination}"
mkdir -p "${ghostty_destination}" "${terminfo_destination}"
rsync -a --delete "${ghostty_source}/" "${ghostty_destination}/"
rsync -a --delete "${terminfo_source}/" "${terminfo_destination}/"

# zmx (new). Selection mirrors build-zmx.sh:
#   - ALAS_ZMX_TARGET_ARCH (CI/release per-slice override) wins.
#   - CURRENT_ARCH=undefined_arch (multi-arch parent in Xcode) means a
#     universal slice — pick the lipo'd binary build-zmx.sh produced.
#   - Otherwise use CURRENT_ARCH, or uname -m for local-dev fallback.
if [ -n "${ALAS_ZMX_TARGET_ARCH:-}" ]; then
    zmx_arch="${ALAS_ZMX_TARGET_ARCH}"
elif [ "${CURRENT_ARCH:-}" = "undefined_arch" ]; then
    zmx_arch="universal"
else
    zmx_arch="${CURRENT_ARCH:-$(uname -m)}"
fi
zmx_source="${SRCROOT}/.build/zmx/${zmx_arch}/install/bin/zmx"
zmx_destination_dir="${destination_root}/zmx"
zmx_destination="${zmx_destination_dir}/zmx"

if [ -x "${zmx_source}" ]; then
    rm -rf "${zmx_destination_dir}"
    mkdir -p "${zmx_destination_dir}"
    rsync -a "${zmx_source}" "${zmx_destination}"
    chmod +x "${zmx_destination}"
    for linux_arch in x86_64 aarch64; do
        linux_source="${SRCROOT}/.build/zmx/linux-${linux_arch}/install/bin/zmx"
        linux_destination_dir="${zmx_destination_dir}/linux-${linux_arch}"
        if [ ! -x "${linux_source}" ]; then
            echo "embed-ghostty-resources.sh: error: Linux zmx binary not found or not executable at ${linux_source}" >&2
            exit 1
        fi
        mkdir -p "${linux_destination_dir}"
        rsync -a "${linux_source}" "${linux_destination_dir}/zmx"
        chmod +x "${linux_destination_dir}/zmx"
    done
elif [ "${ALAS_ZMX_OPTIONAL:-}" = "1" ]; then
    # Drop any previously bundled zmx so an incremental optional build does
    # not silently ship a stale helper despite warning that panes will not
    # persist.
    rm -rf "${zmx_destination_dir}"
    echo "embed-ghostty-resources.sh: warning: zmx binary not found or not executable at ${zmx_source}; terminal panes will not persist across app quit" >&2
else
    echo "embed-ghostty-resources.sh: error: zmx binary not found or not executable at ${zmx_source}" >&2
    exit 1
fi

# Alas remote helper. Keep separate per-platform slices because the app selects
# one from the remote host's uname result before pushing it over scp.
helper_destination_root="${destination_root}/alas-helper"
rm -rf "${helper_destination_root}"
mkdir -p "${helper_destination_root}"
helper_targets=(
    "linux-x86_64:x86_64-unknown-linux-musl"
    "linux-aarch64:aarch64-unknown-linux-musl"
    "macos-x86_64:x86_64-apple-darwin"
    "macos-aarch64:aarch64-apple-darwin"
)
for mapping in "${helper_targets[@]}"; do
    resource_dir="${mapping%%:*}"
    rust_target="${mapping#*:}"
    helper_source="${SRCROOT}/.build/alas-helper/${rust_target}/release/alas-helper"
    if [ ! -x "${helper_source}" ]; then
        echo "embed-ghostty-resources.sh: error: Alas helper binary not found at ${helper_source}" >&2
        exit 1
    fi
    mkdir -p "${helper_destination_root}/${resource_dir}"
    rsync -a "${helper_source}" "${helper_destination_root}/${resource_dir}/alas-helper"
    chmod +x "${helper_destination_root}/${resource_dir}/alas-helper"
done
rsync -a "${SRCROOT}/AlasHelper/manifest.json" "${helper_destination_root}/manifest.json"

# fff search backend dylib. Selection mirrors build-fff.sh.
if [ -n "${ALAS_FFF_TARGET_ARCH:-}" ]; then
    fff_arch="${ALAS_FFF_TARGET_ARCH}"
elif [ "${CURRENT_ARCH:-}" = "undefined_arch" ]; then
    fff_arch="universal"
else
    fff_arch="${CURRENT_ARCH:-$(uname -m)}"
fi

fff_source="${SRCROOT}/.build/fff/${fff_arch}/install/lib/libfff_c.dylib"
fff_destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
fff_destination="${fff_destination_dir}/libfff_c.dylib"

if [ ! -f "${fff_source}" ]; then
    echo "embed-ghostty-resources.sh: error: fff dylib not found at ${fff_source}" >&2
    exit 1
fi

mkdir -p "${fff_destination_dir}"
rsync -a "${fff_source}" "${fff_destination}"
install_name_tool -id @rpath/libfff_c.dylib "${fff_destination}"
codesign --force --sign - "${fff_destination}" >/dev/null
