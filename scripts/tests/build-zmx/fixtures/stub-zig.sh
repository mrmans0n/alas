#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "build" ]; then
    # Unknown subcommand -- print something so shasum still succeeds when
    # callers stat the binary itself.
    echo "stub-zig: unsupported subcommand: ${1:-}" >&2
    exit 2
fi

# Find --prefix <path> in remaining args.
shift
prefix=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        *)        shift ;;
    esac
done
[ -n "${prefix}" ] || { echo "stub-zig: missing --prefix" >&2; exit 1; }

mkdir -p "${prefix}/bin"
printf '#!/bin/sh\necho stub-zmx\n' > "${prefix}/bin/zmx"
chmod +x "${prefix}/bin/zmx"
