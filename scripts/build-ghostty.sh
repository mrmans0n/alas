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
# Returns non-zero if any copy fails (e.g. the entry was concurrently GC'd or
# replaced between cache_entry_valid and this call). Caller falls back to a
# local build — the shared cache must never break the build.
populate_worktree_from_cache() {
  local entry="$1" fp="$2"
  rm -rf "${xcframework_path}" "${ghostty_build_root}/share"
  cp -c -R "${entry}/GhosttyKit.xcframework" "${ghostty_build_root}/" 2>/dev/null \
    || return 1
  cp -c -R "${entry}/share" "${ghostty_build_root}/" 2>/dev/null \
    || return 1
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
  local arch_dir deadline now stale_after pid_file lock_pid
  arch_dir="$(dirname "${entry}")"
  if ! mkdir -p "${arch_dir}" 2>/dev/null; then
    return 1
  fi

  stale_after="${ALAS_GHOSTTY_LOCK_STALE_SECS:-60}"
  deadline=$(( $(date +%s) + ${ALAS_GHOSTTY_LOCK_TIMEOUT_SECS:-1800} ))

  while true; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      _held_lock="${lock_dir}"
      echo $$ > "${lock_dir}/pid" 2>/dev/null || true
      return 0
    fi

    # Did the winner finish?
    if cache_entry_valid "${entry}" "${fp}"; then
      return 2
    fi

    now="$(date +%s)"
    if [ "${now}" -ge "${deadline}" ]; then
      warn "shared cache lock wait exceeded deadline; building locally"
      return 1
    fi

    # Stale lock: dir older than stale_after AND its PID file references a
    # process that isn't running. `stat -f %m` is BSD/macOS; coreutils is
    # `stat -c %Y`.
    local lock_mtime
    if lock_mtime="$(stat -f %m "${lock_dir}" 2>/dev/null)" \
       || lock_mtime="$(stat -c %Y "${lock_dir}" 2>/dev/null)"; then
      if [ $(( now - lock_mtime )) -ge "${stale_after}" ]; then
        pid_file="${lock_dir}/pid"
        lock_pid=""
        [ -f "${pid_file}" ] && lock_pid="$(cat "${pid_file}" 2>/dev/null || true)"
        if [ -z "${lock_pid}" ] || ! kill -0 "${lock_pid}" 2>/dev/null; then
          warn "removing stale lock at ${lock_dir} (pid=${lock_pid:-unknown})"
          rm -rf "${lock_dir}" 2>/dev/null || true
          # Loop and retry mkdir.
          continue
        fi
      fi
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

# Drop all but the newest N entries (by mtime) under "$1". Entries with a
# matching sibling .lock dir are skipped. .tmp.* staging dirs are not eligible.
gc_cache() {
  local arch_dir="$1" keep="$2"
  [ -d "${arch_dir}" ] || return 0
  # Build a list of (mtime, path) for entries that are NOT .lock / .tmp.* /
  # currently locked. BSD stat first, then GNU stat.
  local entries
  entries="$(
    find "${arch_dir}" -maxdepth 1 -mindepth 1 -type d \
      ! -name '*.lock' ! -name '*.tmp.*' -print0 \
      | while IFS= read -r -d '' p; do
          base="$(basename "${p}")"
          [ -d "${arch_dir}/${base}.lock" ] && continue
          if mt="$(stat -f %m "${p}" 2>/dev/null)" || mt="$(stat -c %Y "${p}" 2>/dev/null)"; then
            printf '%s\t%s\n' "${mt}" "${p}"
          fi
        done \
      | sort -rn
  )"
  local count=0
  local IFS=$'\n'
  for line in ${entries}; do
    count=$((count + 1))
    if [ "${count}" -gt "${keep}" ]; then
      local path="${line#*$'\t'}"
      rm -rf "${path}"
    fi
  done
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

if [ "${ALAS_GHOSTTY_CACHE_DISABLE:-}" = "1" ]; then
  build_and_install_local
  exit 0
fi

shared_entry="${ghostty_cache_root}/${fingerprint}"
if cache_entry_valid "${shared_entry}" "${fingerprint}"; then
  if populate_worktree_from_cache "${shared_entry}" "${fingerprint}"; then
    exit 0
  fi
  warn "cache entry vanished mid-copy; falling back to local build"
fi

lock_rc=0
acquire_cache_lock "${shared_entry}" "${fingerprint}" || lock_rc=$?
case "${lock_rc}" in
  0)
    # We hold the lock. Re-check after acquisition (another process may have
    # published just before we mkdir'd).
    if cache_entry_valid "${shared_entry}" "${fingerprint}" \
       && populate_worktree_from_cache "${shared_entry}" "${fingerprint}"; then
      release_cache_lock
      exit 0
    fi
    build_and_install_local
    _gc_arch_dir="$(dirname "${shared_entry}")"
    if publish_to_cache "${shared_entry}" "${fingerprint}"; then
      release_cache_lock
      gc_cache "${_gc_arch_dir}" "${ghostty_cache_keep}" \
        || warn "cache GC failed"
    else
      warn "failed to publish to shared cache (${shared_entry})"
      release_cache_lock
    fi
    ;;
  2)
    # Winner published while we waited.
    if ! populate_worktree_from_cache "${shared_entry}" "${fingerprint}"; then
      warn "cache entry vanished after winner published; falling back to local build"
      build_and_install_local
    fi
    ;;
  *)
    warn "could not acquire shared cache lock; building locally without publishing"
    build_and_install_local
    ;;
esac
