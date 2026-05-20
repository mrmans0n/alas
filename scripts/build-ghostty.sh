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
_held_lock=""
_held_staging=""
_script_cleanup() {
  rm -rf "${_fake_xcrun_dir}" 2>/dev/null || true
  [ -n "${_held_staging}" ] && rm -rf "${_held_staging}" 2>/dev/null || true
  if [ -n "${_held_lock}" ] && [ -d "${_held_lock}" ]; then
    rm -rf "${_held_lock}" 2>/dev/null || true
  fi
}
trap _script_cleanup EXIT

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

# True iff <entry-dir> contains a complete, fingerprint-matching cache entry.
cache_entry_valid() {
  local dir="$1" fp="$2"
  [ -f "${dir}/fingerprint" ] || return 1
  [ -d "${dir}/GhosttyKit.xcframework" ] || return 1
  [ -d "${dir}/share/ghostty" ] || return 1
  [ -d "${dir}/share/terminfo" ] || return 1
  [ "$(cat "${dir}/fingerprint")" = "${fp}" ] || return 1
}

# Populate the worktree from a known-valid cache entry. Uses APFS clonefile
# (`cp -c`) for near-zero disk cost. Writes the local fingerprint LAST so a
# crash mid-copy leaves the worktree visibly incomplete and triggers a rebuild.
populate_worktree_from_cache() {
  local entry="$1" fp="$2"
  rm -rf "${xcframework_path}" "${ghostty_build_root}/share"
  cp -c -R "${entry}/GhosttyKit.xcframework" "${ghostty_build_root}/"
  cp -c -R "${entry}/share" "${ghostty_build_root}/"
  printf '%s\n' "${fp}" > "${ghostty_fingerprint_path}"
}

# Atomic publish: stage in <fp>.tmp.<pid>, write fingerprint last, then mv.
# Returns 0 on success, non-zero on any failure (caller treats as non-fatal).
# Sets _held_staging so _script_cleanup can remove the staging dir on interrupt.
publish_to_cache() {
  local entry="$1" fp="$2"
  local arch_dir
  arch_dir="$(dirname "${entry}")"
  mkdir -p "${arch_dir}" || return 1
  _held_staging="${arch_dir}/${fp}.tmp.$$"
  rm -rf "${_held_staging}"
  mkdir "${_held_staging}" || { _held_staging=""; return 1; }
  cp -c -R "${xcframework_path}" "${_held_staging}/" || { rm -rf "${_held_staging}"; _held_staging=""; return 1; }
  cp -c -R "${ghostty_build_root}/share" "${_held_staging}/" || { rm -rf "${_held_staging}"; _held_staging=""; return 1; }
  printf '%s\n' "${fp}" > "${_held_staging}/fingerprint" || { rm -rf "${_held_staging}"; _held_staging=""; return 1; }
  # Remove any stale entry before renaming so `mv` replaces it rather than
  # nesting the staging dir inside it (macOS mv semantics when target exists).
  rm -rf "${entry}"
  # Atomic rename. If another process has just published the same entry
  # (unlikely without locking, but tolerate it), treat as success.
  if ! mv "${_held_staging}" "${entry}" 2>/dev/null; then
    rm -rf "${_held_staging}"
    _held_staging=""
    [ -d "${entry}" ] && return 0 || return 1
  fi
  _held_staging=""
}

# Try to mkdir-atomic-acquire the per-fingerprint lock. Loser polls (1s) until
# the fingerprint is published, at which point the lock is released. Returns:
#   0 — lock acquired (caller must build + publish)
#   2 — winner already published while we waited (cache now valid; no build needed)
#   1 — couldn't acquire (e.g., cache root unwritable); caller should build locally
#       WITHOUT publishing.
acquire_cache_lock() {
  local entry="$1" fp="$2"
  local lock_dir="${entry}.lock"
  local arch_dir
  arch_dir="$(dirname "${entry}")"
  if ! mkdir -p "${arch_dir}" 2>/dev/null; then
    return 1
  fi
  while true; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      _held_lock="${lock_dir}"
      echo $$ > "${lock_dir}/pid" 2>/dev/null || true
      return 0
    fi
    # Lock held by someone else. Wait for them; recheck cache.
    if cache_entry_valid "${entry}" "${fp}"; then
      return 2
    fi
    sleep 1
  done
}

release_cache_lock() {
  if [ -n "${_held_lock}" ]; then
    rm -rf "${_held_lock}" 2>/dev/null || true
    _held_lock=""
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

shared_entry="${ghostty_cache_root}/${fingerprint}"
if cache_entry_valid "${shared_entry}" "${fingerprint}"; then
  populate_worktree_from_cache "${shared_entry}" "${fingerprint}"
  exit 0
fi

lock_rc=0
acquire_cache_lock "${shared_entry}" "${fingerprint}" || lock_rc=$?
case "${lock_rc}" in
  0)
    # We hold the lock. Re-check after acquisition (another process may have
    # published just before we mkdir'd).
    if cache_entry_valid "${shared_entry}" "${fingerprint}"; then
      populate_worktree_from_cache "${shared_entry}" "${fingerprint}"
      release_cache_lock
      exit 0
    fi
    build_and_install_local
    if ! publish_to_cache "${shared_entry}" "${fingerprint}"; then
      warn "failed to publish to shared cache (${shared_entry})"
    fi
    release_cache_lock
    ;;
  2)
    # Winner published while we waited.
    populate_worktree_from_cache "${shared_entry}" "${fingerprint}"
    ;;
  *)
    warn "could not acquire shared cache lock; building locally without publishing"
    build_and_install_local
    ;;
esac
