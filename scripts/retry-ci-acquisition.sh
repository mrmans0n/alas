#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: retry-ci-acquisition.sh swift package resolve ... | rustup toolchain install ... | rustup target add ..." >&2
    exit 64
fi

executable="$1"
shift
first_subcommand="${1:-}"
second_subcommand="${2:-}"
shift 2

case "${executable##*/}:${first_subcommand}:${second_subcommand}" in
    swift:package:resolve)
        operation="swiftpm"
        ;;
    rustup:toolchain:install|rustup:target:add)
        operation="rustup"
        ;;
    *)
        echo "retry-ci-acquisition.sh: refusing non-acquisition command: ${executable} ${first_subcommand} ${second_subcommand}" >&2
        exit 64
        ;;
esac

delay_seconds="${ALAS_CI_ACQUISITION_RETRY_DELAY_SECONDS:-5}"
if [[ ! "${delay_seconds}" =~ ^[0-9]+$ ]] || [ "${delay_seconds}" -gt 60 ]; then
    echo "retry-ci-acquisition.sh: retry delay must be an integer from 0 to 60 seconds" >&2
    exit 64
fi

temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
attempt_output="$(mktemp "${temporary_root%/}/alas-ci-acquisition.XXXXXX")"
trap 'rm -f "${attempt_output}"' EXIT

is_retryable_failure() {
    case "${operation}" in
        swiftpm)
            grep -Eq \
                "error: RPC failed; HTTP 400 curl 22 The requested URL returned error: 400|error: Git command .*org\\.swift\\.swiftpm/repositories/.*failed: fatal: cannot change to .*org\\.swift\\.swiftpm/repositories/.*: No such file or directory" \
                "${attempt_output}"
            ;;
        rustup)
            normalized_output="$(< "${attempt_output}")"
            normalized_output="${normalized_output//$'\n'/ }"
            rustup_dns_pattern="could not download file from 'https://static\\.rust-lang\\.org/dist/[^']+'.*dns error: failed to lookup address information"
            [[ "${normalized_output}" =~ ${rustup_dns_pattern} ]]
            ;;
    esac
}

command=("${executable}" "${first_subcommand}" "${second_subcommand}" "$@")
for attempt in 1 2 3; do
    if "${command[@]}" >"${attempt_output}" 2>&1; then
        cat "${attempt_output}"
        exit 0
    else
        status=$?
    fi

    cat "${attempt_output}"
    if [ "${status}" -ge 128 ]; then
        exit "${status}"
    fi
    if [ "${attempt}" -eq 3 ] || ! is_retryable_failure; then
        exit "${status}"
    fi

    if [ "${operation}" = "swiftpm" ] && grep -Eq \
        "error: Git command .*org\\.swift\\.swiftpm/repositories/.*failed: fatal: cannot change to .*org\\.swift\\.swiftpm/repositories/.*: No such file or directory" \
        "${attempt_output}"; then
        command=("${executable}" "${first_subcommand}" --disable-dependency-cache "${second_subcommand}" "$@")
    fi

    sleep_seconds=$((delay_seconds * attempt))
    echo "retry-ci-acquisition.sh: recognized ${operation} acquisition failure; retrying attempt $((attempt + 1))/3 in ${sleep_seconds}s" >&2
    sleep "${sleep_seconds}"
done
