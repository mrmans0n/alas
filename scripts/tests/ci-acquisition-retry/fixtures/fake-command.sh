#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-} ${3:-}" in
    "package resolve --package-path"|"package --disable-dependency-cache resolve"|"toolchain install 1.97.0"|"target add --toolchain") ;;
    *) echo "unexpected command: $*" >&2; exit 2 ;;
esac

calls="$(cat "${ACQUISITION_CALLS_FILE}")"
calls=$((calls + 1))
printf '%s\n' "${calls}" > "${ACQUISITION_CALLS_FILE}"
printf '%s\n' "$*" >> "${ACQUISITION_ARGUMENTS_FILE}"

if [ "${calls}" -le "${ACQUISITION_FAIL_UNTIL:-0}" ]; then
    cat "${ACQUISITION_FIXTURE}" >&2
    if [ "${ACQUISITION_SELF_SIGTERM:-0}" = "1" ]; then
        kill -TERM "$$"
    fi
    exit "${ACQUISITION_FAILURE_STATUS:-71}"
fi

echo "acquisition fixture succeeded"
