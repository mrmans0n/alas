#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${test_dir}/../../.." && pwd)"
retry_helper="${repo_root}/scripts/retry-ci-acquisition.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin"
cp "${test_dir}/fixtures/fake-command.sh" "${tmp}/bin/swift"
cp "${test_dir}/fixtures/fake-command.sh" "${tmp}/bin/rustup"
chmod +x "${tmp}/bin/swift" "${tmp}/bin/rustup"

run_retry_case() {
    local label="$1" fixture="$2" expected_calls="$3" status=0
    shift 3
    local calls_file="${tmp}/${label}.calls" args_file="${tmp}/${label}.args" output_file="${tmp}/${label}.out"
    printf '0\n' > "${calls_file}"
    if PATH="${tmp}/bin:${PATH}" \
        ACQUISITION_CALLS_FILE="${calls_file}" \
        ACQUISITION_ARGUMENTS_FILE="${args_file}" \
        ACQUISITION_FIXTURE="${test_dir}/fixtures/${fixture}" \
        ACQUISITION_FAIL_UNTIL="${ACQUISITION_FAIL_UNTIL_VALUE:-1}" \
        ACQUISITION_FAILURE_STATUS="${ACQUISITION_FAILURE_STATUS_VALUE:-71}" \
        ALAS_CI_ACQUISITION_RETRY_DELAY_SECONDS=0 \
        bash "${retry_helper}" "$@" > "${output_file}" 2>&1; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "${status}" > "${output_file}.status"
    [ "$(cat "${calls_file}")" = "${expected_calls}" ] || {
        echo "${label}: expected ${expected_calls} attempts, got $(cat "${calls_file}")" >&2
        cat "${output_file}" >&2
        return 1
    }
    echo "${output_file}"
}

assert_successful_retry() {
    local label="$1" fixture="$2"
    shift 2
    local output_file
    output_file="$(run_retry_case "${label}" "${fixture}" 2 "$@" | tail -n 1)"
    [ "$(cat "${output_file}.status")" = "0" ] || { echo "${label}: expected success" >&2; return 1; }
    grep -q "attempt 2/3" "${output_file}" || { echo "${label}: second attempt not logged" >&2; return 1; }
}

assert_successful_retry swiftpm-http400 swiftpm-http400.log \
    swift package resolve --package-path Packages/AlasCore
assert_successful_retry swiftpm-missing-checkout swiftpm-missing-checkout.log \
    swift package resolve --package-path Packages/AlasCore
grep -Fxq "package --disable-dependency-cache resolve --package-path Packages/AlasCore" \
    "${tmp}/swiftpm-missing-checkout.args" || { echo "missing checkout retry did not bypass the shared dependency cache" >&2; exit 1; }
if grep -q -- "--disable-dependency-cache" "${tmp}/swiftpm-http400.args"; then
    echo "HTTP 400 retry unexpectedly bypassed the dependency cache" >&2
    exit 1
fi
assert_successful_retry rustup-toolchain rustup-dns.log \
    rustup toolchain install 1.97.0 --profile minimal
assert_successful_retry rustup-target rustup-dns.log \
    rustup target add --toolchain 1.97.0 aarch64-apple-darwin

run_interrupted_case() {
    local label="$1" expected_status="$2" self_sigterm="$3" status=0
    local calls_file="${tmp}/${label}.calls"
    printf '0\n' > "${calls_file}"
    if PATH="${tmp}/bin:${PATH}" \
        ACQUISITION_CALLS_FILE="${calls_file}" \
        ACQUISITION_ARGUMENTS_FILE="${tmp}/${label}.args" \
        ACQUISITION_FIXTURE="${test_dir}/fixtures/rustup-dns.log" \
        ACQUISITION_FAIL_UNTIL=9 \
        ACQUISITION_FAILURE_STATUS="${expected_status}" \
        ACQUISITION_SELF_SIGTERM="${self_sigterm}" \
        ALAS_CI_ACQUISITION_RETRY_DELAY_SECONDS=0 \
        bash "${retry_helper}" rustup toolchain install 1.97.0 --profile minimal > "${tmp}/${label}.out" 2>&1; then
        status=0
    else
        status=$?
    fi
    [ "${status}" = "${expected_status}" ] || {
        echo "${label}: expected original interruption status ${expected_status}, got ${status}" >&2
        cat "${tmp}/${label}.out" >&2
        return 1
    }
    [ "$(cat "${calls_file}")" = "1" ] || {
        echo "${label}: interruption was retried $(cat "${calls_file}") times" >&2
        return 1
    }
}

run_interrupted_case interrupted-130 130 0
run_interrupted_case interrupted-143 143 0
run_interrupted_case self-sigterm 143 1

unknown_calls="${tmp}/unknown.calls"
printf '0\n' > "${unknown_calls}"
unknown_status=0
if PATH="${tmp}/bin:${PATH}" \
    ACQUISITION_CALLS_FILE="${unknown_calls}" \
    ACQUISITION_ARGUMENTS_FILE="${tmp}/unknown.args" \
    ACQUISITION_FIXTURE="${test_dir}/fixtures/unknown-error.log" \
    ACQUISITION_FAIL_UNTIL=1 \
    ACQUISITION_FAILURE_STATUS=73 \
    ALAS_CI_ACQUISITION_RETRY_DELAY_SECONDS=0 \
    bash "${retry_helper}" swift package resolve --package-path Packages/AlasCore > "${tmp}/unknown.out" 2>&1; then
    unknown_status=0
else
    unknown_status=$?
fi
[ "${unknown_status}" = "73" ] || { echo "unknown error: expected original exit 73, got ${unknown_status}" >&2; exit 1; }
[ "$(cat "${unknown_calls}")" = "1" ] || { echo "unknown error was retried" >&2; exit 1; }

exhausted_calls="${tmp}/exhausted.calls"
printf '0\n' > "${exhausted_calls}"
exhausted_status=0
if PATH="${tmp}/bin:${PATH}" \
    ACQUISITION_CALLS_FILE="${exhausted_calls}" \
    ACQUISITION_ARGUMENTS_FILE="${tmp}/exhausted.args" \
    ACQUISITION_FIXTURE="${test_dir}/fixtures/rustup-dns.log" \
    ACQUISITION_FAIL_UNTIL=9 \
    ACQUISITION_FAILURE_STATUS=74 \
    ALAS_CI_ACQUISITION_RETRY_DELAY_SECONDS=0 \
    bash "${retry_helper}" rustup toolchain install 1.97.0 --profile minimal > "${tmp}/exhausted.out" 2>&1; then
    exhausted_status=0
else
    exhausted_status=$?
fi
[ "${exhausted_status}" = "74" ] || { echo "exhaustion: expected final exit 74, got ${exhausted_status}" >&2; exit 1; }
[ "$(cat "${exhausted_calls}")" = "3" ] || { echo "exhaustion: expected 3 attempts" >&2; exit 1; }

disallowed_status=0
if PATH="${tmp}/bin:${PATH}" \
    ACQUISITION_CALLS_FILE="${tmp}/disallowed.calls" \
    ACQUISITION_ARGUMENTS_FILE="${tmp}/disallowed.args" \
    bash "${retry_helper}" swift test --package-path Packages/AlasCore > "${tmp}/disallowed.out" 2>&1; then
    disallowed_status=0
else
    disallowed_status=$?
fi
[ "${disallowed_status}" = "64" ] || { echo "helper accepted a non-acquisition command" >&2; exit 1; }
[ ! -e "${tmp}/disallowed.calls" ] || { echo "disallowed command reached executable" >&2; exit 1; }
