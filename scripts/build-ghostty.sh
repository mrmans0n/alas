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

# Target arch for the Ghostty build. Defaults to the host arch (uname -m)
# so local dev keeps working unchanged; CI sets this explicitly to produce
# both arm64 and x86_64 slices from one Apple Silicon runner via zig's
# cross-compilation.
target_arch="${ALAS_GHOSTTY_TARGET_ARCH:-$(uname -m)}"
arch="${target_arch}"
ghostty_cache_root_default="${HOME}/Library/Caches/Alas/GhosttyKit"
ghostty_cache_root="${ALAS_GHOSTTY_CACHE_DIR:-${ghostty_cache_root_default}}/${arch}"
ghostty_cache_keep="${ALAS_GHOSTTY_CACHE_KEEP:-5}"
ghostty_retry_delays=()
for delay in ${ALAS_GHOSTTY_RETRY_DELAYS:-5 15 30 60 120 180}; do
  ghostty_retry_delays+=("${delay}")
done

# Emit a one-line warning to stderr. Does not exit.
warn() { echo "build-ghostty.sh: warning: $*" >&2; }

# Resolve the path to the zig binary that build_and_install_local will use.
# Echoes the path (which may not exist yet). Mirrors the resolution logic in
# build_and_install_local; exists separately so print_fingerprint can include
# the toolchain identity without invoking the full build.
resolve_zig_bin() {
  if [ -n "${ALAS_ZIG_BIN:-}" ]; then
    printf '%s\n' "${ALAS_ZIG_BIN}"
  else
    printf '%s/bin/zig\n' "$(brew --prefix zig@0.15 2>/dev/null)"
  fi
}

print_fingerprint() {
  (
    cd "${ghostty_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      if [ -f "${srcroot}/mise.toml" ]; then shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'; fi
      # Toolchain identity: different zig binaries can produce ABI-incompatible
      # artifacts at the same Ghostty commit. Include the resolved path AND
      # content hash so ALAS_ZIG_BIN overrides and brew upgrades both break
      # cache reuse rather than silently mixing artifacts.
      zig_bin_for_fp="$(resolve_zig_bin)"
      printf '%s\n' "${zig_bin_for_fp}"
      if [ -x "${zig_bin_for_fp}" ]; then
        shasum -a 256 "${zig_bin_for_fp}" 2>/dev/null | awk '{print $1}'
      else
        echo "no-zig"
      fi
      # Target arch participates in the fingerprint: a different -Dtarget
      # produces a different binary even at identical Ghostty/toolchain state,
      # so two arches must not share a cache entry.
      printf 'target=%s\n' "${target_arch}"
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

run_zig_build_with_retries() {
  local zig_bin="$1"
  local zig_arch="$2"
  local attempt status delay
  attempt=1

  while true; do
    rm -rf "${ghostty_dir}/macos/GhosttyKit.xcframework" "${ghostty_build_root}/share"
    if (
      cd "${ghostty_dir}"
      "${zig_bin}" build \
        -Doptimize=ReleaseFast \
        -Demit-xcframework=true \
        -Dsentry=false \
        -Dtarget="${zig_arch}-macos.14.0" \
        --prefix "${ghostty_build_root}" \
        --cache-dir "${ghostty_local_cache_dir}" \
        --global-cache-dir "${ghostty_global_cache_dir}"
    ) &&
      [ -d "${ghostty_dir}/macos/GhosttyKit.xcframework" ] &&
      [ -d "${ghostty_resources_path}" ] &&
      [ -d "${ghostty_terminfo_path}" ]; then
      return 0
    fi

    status=$?
    if [ "${attempt}" -gt "${#ghostty_retry_delays[@]}" ]; then
      return "${status}"
    fi

    delay="${ghostty_retry_delays[$((attempt - 1))]}"
    warn "zig build failed with exit ${status}; retrying in ${delay}s (attempt $((attempt + 1))/$(( ${#ghostty_retry_delays[@]} + 1 )))"
    sleep "${delay}"
    attempt=$((attempt + 1))
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
    zig_bin="$(resolve_zig_bin)"
    if [ ! -x "${zig_bin}" ]; then
      echo "error: zig not found (looked at ${zig_bin}). Install with: brew install zig@0.15, or set ALAS_ZIG_BIN" >&2
      exit 1
    fi
    # Zig uses the LLVM triple name `aarch64`, not Apple's `arm64`. Translate
    # before passing to zig; everything else (cache path, fingerprint, env
    # var) keeps the Apple name for consistency with `uname -m` and Xcode.
    # Pin macOS 14.0 in the triple so the embedded LC_BUILD_VERSION minos is
    # deterministic and matches project.yml's MACOSX_DEPLOYMENT_TARGET (14.0)
    # — without this, the embedded minos floats with whatever floor zig
    # picks for the bare `*-macos` triple, which is not stable across zig
    # releases. Note: zig 0.15 requires at least a two-component version
    # (14.0), not a bare major (14), to parse the triple correctly.
    case "${target_arch}" in
      arm64)  zig_arch="aarch64" ;;
      x86_64) zig_arch="x86_64" ;;
      *)      echo "error: unsupported target_arch '${target_arch}'" >&2; exit 1 ;;
    esac
    run_zig_build_with_retries "${zig_bin}" "${zig_arch}"
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
  rm -rf "${entry}" 2>/dev/null || true
  # Atomic rename. On failure, only treat as success if the entry that exists
  # actually carries OUR fingerprint (i.e. another publisher won the race with
  # identical content). An old, partial, or mismatched entry left behind by a
  # failed rm must be reported so the caller warns and skips GC.
  if ! mv "${_held_staging}" "${entry}" 2>/dev/null; then
    rm -rf "${_held_staging}" 2>/dev/null || true
    _held_staging=""
    if cache_entry_valid "${entry}" "${fp}"; then
      return 0
    fi
    return 1
  fi
  _held_staging=""
}

# Opaque token identifying a running process beyond just its PID. macOS PIDs
# wrap (32k by default), so `kill -0 ${old_pid}` can succeed against a brand
# new unrelated process and falsely report a stale lock as live. Pairing the
# PID with `ps -o lstart=` (process start time) catches reuse — a different
# token (or empty output) means the original holder is gone.
# Echoes the token (may be empty if ps fails or the PID is gone).
proc_start_token() {
  local pid="$1"
  [ -n "${pid}" ] || { echo ""; return; }
  # Pin LC_ALL=C so the lstart format does not vary between holder and waiter
  # when they run under different LC_TIME settings; any locale difference
  # would otherwise produce different tokens for the same live process and
  # false-reclaim the lock.
  LC_ALL=C ps -o lstart= -p "${pid}" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# Compare the (pid, token) pair from a lock's metadata against the current
# system state. Returns 0 if the original holder is still running, non-zero
# if the holder is gone (including PID-reuse).
lock_holder_alive() {
  local lock_pid="$1" lock_token="$2"
  [ -n "${lock_pid}" ] || return 1
  kill -0 "${lock_pid}" 2>/dev/null || return 1
  # If we recorded a token, the current process with this PID must still
  # match it. Empty recorded token means a legacy lock (or ps unavailable
  # at acquire time) — fall back to kill -0 alone.
  if [ -n "${lock_token}" ]; then
    [ "$(proc_start_token "${lock_pid}")" = "${lock_token}" ] || return 1
  fi
  return 0
}

# Read pid + start-time token from a lock's metadata file. Echoes a single
# line "<pid> <token>"; the token may be empty when the file holds only a PID
# (legacy or partially-written lock). Callers split on the first space.
read_lock_metadata() {
  local pid_file="$1"
  [ -f "${pid_file}" ] || { echo ""; return; }
  local first rest
  if IFS=$' \t' read -r first rest < "${pid_file}" 2>/dev/null; then
    printf '%s %s\n' "${first}" "${rest}"
  fi
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
  local arch_dir deadline now stale_after pid_file lock_meta lock_pid lock_token
  arch_dir="$(dirname "${entry}")"
  if ! mkdir -p "${arch_dir}" 2>/dev/null; then
    return 1
  fi

  stale_after="${ALAS_GHOSTTY_LOCK_STALE_SECS:-60}"
  deadline=$(( $(date +%s) + ${ALAS_GHOSTTY_LOCK_TIMEOUT_SECS:-1800} ))

  while true; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      # Write metadata BEFORE marking the lock as held, so a write failure
      # leaves nothing behind that other processes could mistake for a stale
      # lock owned by us. If we cannot persist (pid, token), the lock is
      # unsafe and we must release it rather than hold a metadataless lock
      # that stale-check would later reclaim.
      if ! printf '%s %s\n' "$$" "$(proc_start_token "$$")" > "${lock_dir}/pid" 2>/dev/null; then
        warn "could not write lock metadata at ${lock_dir}/pid; releasing"
        rm -rf "${lock_dir}" 2>/dev/null || true
        return 1
      fi
      _held_lock="${lock_dir}"
      return 0
    fi

    # If mkdir failed for a reason other than "directory already exists" (e.g.
    # EACCES because the parent is unwritable), the lock dir won't be present.
    # Treating that as contention would stall for the full timeout; instead
    # short-circuit to a local-only build.
    if [ ! -d "${lock_dir}" ]; then
      warn "cannot create lock dir (${lock_dir}); building locally without publishing"
      return 1
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
        lock_meta="$(read_lock_metadata "${pid_file}")"
        lock_pid="${lock_meta%% *}"
        lock_token="${lock_meta#* }"
        [ "${lock_token}" = "${lock_meta}" ] && lock_token=""
        if ! lock_holder_alive "${lock_pid}" "${lock_token}"; then
          warn "removing stale lock at ${lock_dir} (pid=${lock_pid:-unknown})"
          rm -rf "${lock_dir}" 2>/dev/null || true
          # If the lock dir survived the rm (e.g. EACCES on a sudo-owned
          # cache root), we cannot make progress here. Short-circuit rather
          # than spinning to the timeout.
          if [ -d "${lock_dir}" ]; then
            warn "could not remove stale lock dir; building locally without publishing"
            return 1
          fi
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

# Best-effort: remove a sibling lock dir if it's clearly abandoned (dead PID
# and old enough). Mirrors the stale-lock logic from acquire_cache_lock so a
# publisher killed between mv and rmdir (e.g. SIGKILL) doesn't permanently
# exclude its entry from gc_cache via the sibling-.lock check.
maybe_reclaim_stale_lock() {
  local lock_dir="$1"
  [ -d "${lock_dir}" ] || return 0
  local now stale_after lock_mtime lock_meta lock_pid lock_token
  now="$(date +%s)"
  stale_after="${ALAS_GHOSTTY_LOCK_STALE_SECS:-60}"
  if ! lock_mtime="$(stat -f %m "${lock_dir}" 2>/dev/null)" \
     && ! lock_mtime="$(stat -c %Y "${lock_dir}" 2>/dev/null)"; then
    return 0
  fi
  [ $(( now - lock_mtime )) -ge "${stale_after}" ] || return 0
  lock_meta="$(read_lock_metadata "${lock_dir}/pid")"
  lock_pid="${lock_meta%% *}"
  lock_token="${lock_meta#* }"
  [ "${lock_token}" = "${lock_meta}" ] && lock_token=""
  if ! lock_holder_alive "${lock_pid}" "${lock_token}"; then
    warn "removing stale lock at ${lock_dir} (pid=${lock_pid:-unknown})"
    rm -rf "${lock_dir}" 2>/dev/null || true
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
          # Best-effort cleanup of an abandoned sibling lock so a publisher
          # killed between mv and rmdir does not pin this entry forever.
          # (bash 3.2 parses apostrophes inside comments-in-$() as quote
          # openers, so this comment intentionally avoids contractions.)
          maybe_reclaim_stale_lock "${arch_dir}/${base}.lock"
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
  # A publisher that crashed between `mv` and `rmdir` may have left a lock dir
  # next to a valid entry. GC skips entries with a sibling .lock, so without
  # this sweep the entry would become non-evictable.
  maybe_reclaim_stale_lock "${shared_entry}.lock"
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
