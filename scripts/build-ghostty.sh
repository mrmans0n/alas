#!/usr/bin/env bash
set -euo pipefail

# Ensure mise is on PATH (Xcode build phases use a minimal environment)
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

# Workaround: Zig 0.15.2 cannot link executables on macOS 26 (Darwin 25) because
# the macOS 26 SDK's libSystem.tbd only exports arm64e-macos targets, not arm64-macos,
# which causes zig's bundled lld to fail to resolve standard C library symbols.
# We intercept `xcrun --sdk macosx --show-sdk-path` to return a macOS 15 SDK that
# has arm64-macos targets, while the actual Ghostty xcframework is built for the
# native architecture via zig's own cross-compilation infrastructure.
_fake_xcrun_dir="$(mktemp -d)"
trap 'rm -rf "${_fake_xcrun_dir}"' EXIT

# Find the macOS 15 SDK from Command Line Tools (always available alongside Xcode)
_macos15_sdk=""
for _candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.4.sdk
do
    if [ -d "${_candidate}" ]; then
        _macos15_sdk="${_candidate}"
        break
    fi
done

if [ -n "${_macos15_sdk}" ]; then
    cat > "${_fake_xcrun_dir}/xcrun" << XCRUN_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"--show-sdk-path"* ]]; then
    echo "${_macos15_sdk}"
    exit 0
fi
exec /usr/bin/xcrun "\$@"
XCRUN_EOF
    chmod +x "${_fake_xcrun_dir}/xcrun"
    export PATH="${_fake_xcrun_dir}:${PATH}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="${srcroot}"
ghostty_dir="${srcroot}/ThirdParty/ghostty"
ghostty_submodule_path="${ghostty_dir#"${repo_root}/"}"
ghostty_build_root="${srcroot}/.build/ghostty"
ghostty_local_cache_dir="${ghostty_build_root}/.zig-cache"
ghostty_global_cache_dir="${ghostty_build_root}/.zig-global-cache"
ghostty_fingerprint_path="${ghostty_build_root}/fingerprint"
ghostty_legacy_prefix_path="${ghostty_dir}/zig-out"
ghostty_legacy_share_path="${ghostty_legacy_prefix_path}/share"
xcframework_path="${ghostty_build_root}/GhosttyKit.xcframework"
ghostty_resources_path="${ghostty_build_root}/share/ghostty"
ghostty_terminfo_path="${ghostty_build_root}/share/terminfo"

arch="$(uname -m)"
ghostty_cache_root_default="${HOME}/Library/Caches/Alas/GhosttyKit"
ghostty_cache_root="${ALAS_GHOSTTY_CACHE_DIR:-${ghostty_cache_root_default}}/${arch}"
ghostty_cache_keep="${ALAS_GHOSTTY_CACHE_KEEP:-5}"

# Emit a one-line warning to stderr. Does not exit.
warn() { echo "build-ghostty.sh: warning: $*" >&2; }

print_fingerprint() {
  (
    cd "${ghostty_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      if [ -f "${srcroot}/mise.toml" ]; then shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'; fi
    } | shasum -a 256 | awk '{print $1}'
  )
}

prepare_xcframework() {
  local modulemap
  find "${xcframework_path}" -path '*/Headers/module.modulemap' -print0 | while IFS= read -r -d '' modulemap; do
    cat > "${modulemap}" <<'EOF'
module GhosttyKit {
    header "ghostty.h"
    export *
}
EOF
  done
}

# Run zig + rsync xcframework + write local fingerprint. Idempotent.
build_and_install_local() {
  (
    cd "${ghostty_dir}"
    # Use Homebrew's patched zig@0.15 — vanilla Zig 0.15.2 has a known linking
    # issue with Xcode 26.4 (https://codeberg.org/ziglang/zig/issues/31658) that
    # silently strips the embedded apprt symbols (ghostty_app_new etc.) from
    # libghostty.a. Brew's bottle ships with the workaround patch.
    # See ThirdParty/ghostty/HACKING.md. The brew prefix is resolved dynamically
    # because Apple Silicon installs under /opt/homebrew while Intel uses
    # /usr/local. ALAS_ZIG_BIN overrides for tests and custom toolchains.
    if [ -n "${ALAS_ZIG_BIN:-}" ]; then
      zig_bin="${ALAS_ZIG_BIN}"
    else
      zig_bin="$(brew --prefix zig@0.15 2>/dev/null)/bin/zig"
    fi
    if [ ! -x "${zig_bin}" ]; then
      echo "error: zig not found (looked at ${zig_bin}). Install with: brew install zig@0.15, or set ALAS_ZIG_BIN" >&2
      exit 1
    fi
    "${zig_bin}" build \
      -Doptimize=ReleaseFast \
      -Demit-xcframework=true \
      -Dsentry=false \
      --prefix "${ghostty_build_root}" \
      --cache-dir "${ghostty_local_cache_dir}" \
      --global-cache-dir "${ghostty_global_cache_dir}"
  )
  rsync -a --delete "${ghostty_dir}/macos/GhosttyKit.xcframework/" "${xcframework_path}/"
  prepare_xcframework
  printf '%s\n' "${fingerprint}" > "${ghostty_fingerprint_path}"
}

ensure_ghostty_checkout() {
  if [ -f "${ghostty_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${ghostty_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${ghostty_submodule_path}"

  if [ ! -f "${ghostty_dir}/build.zig" ]; then
    echo "error: missing ${ghostty_dir} after submodule update" >&2
    exit 1
  fi
}

ensure_ghostty_checkout

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

rm -rf "${ghostty_legacy_prefix_path}"
mkdir -p "${ghostty_build_root}" "${ghostty_legacy_prefix_path}"
ln -s "${ghostty_build_root}/share" "${ghostty_legacy_share_path}"

if [ -f "${ghostty_fingerprint_path}" ] &&
  [ -d "${xcframework_path}" ] &&
  [ -d "${ghostty_resources_path}" ] &&
  [ -d "${ghostty_terminfo_path}" ] &&
  [ "$(cat "${ghostty_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

build_and_install_local
