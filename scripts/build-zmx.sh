#!/usr/bin/env bash
set -euo pipefail

# Ensure mise/brew toolchains are reachable from Xcode build phases.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
zmx_src="${srcroot}/ThirdParty/zmx"
# Target arch precedence:
#   1. ALAS_ZMX_TARGET_ARCH — explicit CI/release override
#   2. CURRENT_ARCH — Xcode's per-slice arch (must match embed-ghostty-resources.sh)
#   3. uname -m — local-dev fallback for host-native builds
# When CURRENT_ARCH is the placeholder Xcode emits for multi-arch parents
# (`undefined_arch`) — typically a Release archive without ONLY_ACTIVE_ARCH —
# we build a universal binary by lipo'ing both slices so the embedded
# zmx works on either arch the parent app might run on.
_xcode_arch="${CURRENT_ARCH:-}"
if [ -z "${ALAS_ZMX_TARGET_ARCH:-}" ] && [ "${_xcode_arch}" = "undefined_arch" ]; then
    target_arch="universal"
else
    if [ "${_xcode_arch}" = "undefined_arch" ]; then
        _xcode_arch=""
    fi
    target_arch="${ALAS_ZMX_TARGET_ARCH:-${_xcode_arch:-$(uname -m)}}"
fi
zmx_build_root="${srcroot}/.build/zmx/${target_arch}"
zmx_install_prefix="${zmx_build_root}/install"
zmx_output="${zmx_install_prefix}/bin/zmx"
zmx_local_cache_dir="${zmx_build_root}/.zig-cache"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
cache_root_default="${HOME}/Library/Caches/Alas/zmx"
cache_root="${ALAS_ZMX_CACHE_DIR:-${cache_root_default}}/${target_arch}"
keep="${ALAS_ZMX_CACHE_KEEP:-5}"
retry_delays=()
for delay in ${ALAS_ZMX_RETRY_DELAYS:-5 15 30}; do
    retry_delays+=("${delay}")
done

warn() { echo "build-zmx.sh: warning: $*" >&2; }
die()  { echo "build-zmx.sh: error: $*" >&2; exit 1; }

# Optional opt-out: when the dev intentionally builds without zmx (no zig
# toolchain, no submodule), ALAS_ZMX_OPTIONAL=1 downgrades any blocking
# precondition to a warning so embed-ghostty-resources.sh can take the
# matching optional path. Without this, the pre-build phase would fail
# before the embed phase ever runs, making the opt-out unreachable.
#
# Also remove any previously built zmx binary for this arch so a worktree
# that built zmx before (e.g. on a different host or before the toolchain
# was uninstalled) does not silently ship the stale helper via the
# `-x` check in embed-ghostty-resources.sh. For the universal recursive
# path, every per-slice install dir is wiped too.
skip_if_optional() {
    if [ "${ALAS_ZMX_OPTIONAL:-}" = "1" ]; then
        if [ "${target_arch}" = "universal" ]; then
            rm -f \
                "${srcroot}/.build/zmx/arm64/install/bin/zmx" \
                "${srcroot}/.build/zmx/x86_64/install/bin/zmx" \
                "${zmx_output}"
        else
            rm -f "${zmx_output}"
        fi
        warn "$*; skipping zmx build (ALAS_ZMX_OPTIONAL=1)"
        exit 0
    fi
    die "$*"
}

# Universal-build fast path: recursively invoke this script for each slice,
# then `lipo` the results. Each per-arch recursive call goes through the
# normal cache, so re-archives with no zmx change short-circuit on both
# slices. Done BEFORE we touch the zig toolchain so a universal build
# without zig still fails fast on the first per-arch invocation.
if [ "${target_arch}" = "universal" ]; then
    mkdir -p "${zmx_install_prefix}/bin"
    for slice in arm64 x86_64; do
        env ALAS_ZMX_TARGET_ARCH="${slice}" CURRENT_ARCH="" bash "${script_path}"
    done
    arm64_slice="${srcroot}/.build/zmx/arm64/install/bin/zmx"
    x86_64_slice="${srcroot}/.build/zmx/x86_64/install/bin/zmx"
    if [ ! -x "${arm64_slice}" ] || [ ! -x "${x86_64_slice}" ]; then
        # Per-slice builds skipped via ALAS_ZMX_OPTIONAL=1; no binary to lipo.
        skip_if_optional "per-slice zmx builds produced no binary"
    fi
    lipo -create "${arm64_slice}" "${x86_64_slice}" -output "${zmx_output}"
    chmod +x "${zmx_output}"
    echo "build-zmx.sh: produced universal ${zmx_output}"
    exit 0
fi

# Resolve zig. Prefer ALAS_ZIG_BIN override (used by tests and custom
# toolchains); fall back to Homebrew's zig@0.15 (same toolchain build-ghostty.sh
# uses, since vanilla Zig 0.15.2 has Xcode 26 linking issues that brew patches).
resolve_zig_bin() {
    if [ -n "${ALAS_ZIG_BIN:-}" ]; then
        printf '%s\n' "${ALAS_ZIG_BIN}"
    else
        printf '%s/bin/zig\n' "$(brew --prefix zig@0.15 2>/dev/null)"
    fi
}

zig_bin="$(resolve_zig_bin)"
[ -x "${zig_bin}" ] || skip_if_optional "zig not found (looked at ${zig_bin}). Install with: brew install zig@0.15, or set ALAS_ZIG_BIN"

mkdir -p "${zmx_build_root}" "${zmx_install_prefix}/bin" "${cache_root}"

# Submodule presence check.
[ -d "${zmx_src}/.git" ] || [ -f "${zmx_src}/.git" ] || skip_if_optional "submodule missing: ${zmx_src}"

# Fingerprint inputs:
#   - submodule HEAD SHA
#   - submodule working-tree dirt (tracked + untracked) — local patches
#     must invalidate the cache so dev iteration ships the patched binary
#   - target arch + zig binary identity (different arch / toolchain →
#     ABI-incompatible artifact at the same commit)
#   - this script's content hash — build-flag changes must invalidate
zmx_sha="$(git -C "${zmx_src}" rev-parse HEAD)"
# Hash:
#   - tracked-file diff vs HEAD (covers local edits to tracked files)
#   - each untracked file's path AND content (hashing names alone misses
#     edits-in-place to an already-untracked file)
zmx_dirt="$(
    {
        git -C "${zmx_src}" diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
        # Use NUL-delimited list so paths with spaces/newlines stay intact;
        # for each path emit "<path><NUL><sha256-of-content>" then hash.
        while IFS= read -r -d '' untracked; do
            printf '%s\0' "${untracked}"
            shasum -a 256 "${zmx_src}/${untracked}" 2>/dev/null | awk '{print $1}'
        done < <(git -C "${zmx_src}" ls-files --others --exclude-standard -z | LC_ALL=C sort -z) \
            | shasum -a 256
    } | shasum -a 256 | awk '{print $1}'
)"
zig_id="$(shasum -a 256 "${zig_bin}" 2>/dev/null | awk '{print $1}')"
script_id="$(shasum -a 256 "${script_path}" 2>/dev/null | awk '{print $1}')"
fingerprint="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "${zmx_sha}" "${zmx_dirt}" "${target_arch}" "${zig_bin}" "${zig_id}" "${script_id}" | shasum -a 256 | awk '{print $1}')"
cache_dir="${cache_root}/${fingerprint}"
cached_binary="${cache_dir}/zmx"

# Fast path: cache hit -> copy and exit.
if [ -x "${cached_binary}" ]; then
    cp "${cached_binary}" "${zmx_output}"
    chmod +x "${zmx_output}"
    exit 0
fi

# Zig uses the LLVM triple name `aarch64`, not Apple's `arm64`.
case "${target_arch}" in
    arm64)  zig_arch="aarch64" ;;
    x86_64) zig_arch="x86_64" ;;
    *)      die "unsupported target_arch '${target_arch}'" ;;
esac

# Build.
run_zig_build_with_retries() {
    local attempt status delay
    attempt=1
    while true; do
        if (
            cd "${zmx_src}"
            "${zig_bin}" build \
                -Doptimize=ReleaseFast \
                -Dtarget="${zig_arch}-macos.14.0" \
                --prefix "${zmx_install_prefix}" \
                --cache-dir "${zmx_local_cache_dir}" \
                --global-cache-dir "${zmx_global_cache_dir}"
        ); then
            return 0
        fi

        status=$?
        if [ "${attempt}" -gt "${#retry_delays[@]}" ]; then
            return "${status}"
        fi

        delay="${retry_delays[$((attempt - 1))]}"
        warn "zig build failed with exit ${status}; retrying in ${delay}s (attempt $((attempt + 1))/$(( ${#retry_delays[@]} + 1 )))"
        sleep "${delay}"
        attempt=$((attempt + 1))
    done
}

run_zig_build_with_retries
[ -x "${zmx_output}" ] || die "zig build did not produce ${zmx_output}"

# Publish to cache atomically. Use a per-process temp file so two concurrent
# builds with the same fingerprint don't trample each other's `.tmp` mid-copy
# (rename(2) is atomic; collisions on the unique source path can't happen).
mkdir -p "${cache_dir}"
publish_tmp="${cached_binary}.tmp.$$.${RANDOM}"
cp "${zmx_output}" "${publish_tmp}"
mv "${publish_tmp}" "${cached_binary}"

# GC: keep the N most-recent cache entries (by mtime).
# Portable read loop instead of `mapfile` (mapfile is a bash 4+ builtin and
# the macOS-stock /bin/bash that CI resolves via /usr/bin/env bash is 3.2).
entries=()
while IFS= read -r entry; do
    entries+=("${entry}")
done < <(ls -1t "${cache_root}" 2>/dev/null || true)
if [ "${#entries[@]}" -gt "${keep}" ]; then
    for stale in "${entries[@]:${keep}}"; do
        rm -rf "${cache_root}/${stale}"
    done
fi

echo "build-zmx.sh: built ${zmx_output} (cache key ${fingerprint:0:12})"
