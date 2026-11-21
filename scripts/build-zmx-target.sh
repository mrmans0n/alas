#!/usr/bin/env bash
set -euo pipefail

# Run from the zmx checkout. Zig 0.17 takes the global cache via the
# environment. Leave fetched packages in zig-pkg/ so relative dependencies
# still resolve, and reuse them when retrying.
zig_bin="$1"
target="$2"
prefix="$3"
local_cache="$4"
global_cache="$5"
output="$prefix/bin/zmx"

# Check before building because Bash 3 can return 1 for a missing explicit path.
if [[ "$zig_bin" == */* ]] && [ -e "$zig_bin" ] && { [ ! -f "$zig_bin" ] || [ ! -x "$zig_bin" ]; }; then
    echo "build-zmx-target.sh: Zig is not executable: $zig_bin" >&2
    exit 126
fi
if ! command -v "$zig_bin" >/dev/null; then
    echo "build-zmx-target.sh: Zig not found: $zig_bin" >&2
    exit 127
fi

read -r -a retry_delays <<< "${ALAS_ZMX_RETRY_DELAYS:-5 15 30 60 120 180}"
attempt=1
while true; do
    rm -f "$output"
    if ZIG_GLOBAL_CACHE_DIR="$global_cache" "$zig_bin" build \
        -Doptimize=ReleaseFast -Dtarget="$target" \
        --prefix "$prefix" --cache-dir "$local_cache"; then
        if [ -x "$output" ]; then
            exit 0
        fi
        echo "build-zmx-target.sh: Zig produced no executable at $output" >&2
        status=1
    else
        status=$?
    fi

    # Bash reserves 126 and 127 for invocation failures and 128+ for signals.
    if [ "$status" -ge 126 ] || [ "$attempt" -gt "${#retry_delays[@]}" ]; then
        exit "$status"
    fi
    delay="${retry_delays[$((attempt - 1))]}"
    echo "build-zmx-target.sh: warning: $target failed with exit $status; retrying in ${delay}s (attempt $((attempt + 1))/$((${#retry_delays[@]} + 1)))" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
done
