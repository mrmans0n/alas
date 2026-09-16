#!/usr/bin/env bash
set -euo pipefail

batch="${1:?batch index is required}"
batch_count="${2:?batch count is required}"
lane="${3:-ordinary}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="${repo_root}/.build/xcode/results"
mkdir -p "${result_dir}"

selectors=()
while IFS= read -r selector; do
    selectors+=("${selector}")
done < <(bash "${repo_root}/scripts/ci-swift-test-inventory.sh" --batch "${batch}" --batch-count "${batch_count}" --lane "${lane}")

[ "${#selectors[@]}" -gt 0 ] || {
    echo "batch ${batch} has no assigned suites" >&2
    exit 1
}

run_invocation() {
    local result_bundle="$1"
    shift
    local arguments=()
    local selector
    for selector in "$@"; do
        arguments+=( -only-testing "${selector#-only-testing }" )
    done

    local started="$(date +%s)"
    set +e
    xcodebuild -project "${repo_root}/Alas.xcodeproj" -scheme Alas \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${repo_root}/.build/xcode/DerivedData" \
    -clonedSourcePackagesDirPath "${repo_root}/.build/xcode/SourcePackages" \
    -resultBundlePath "${result_bundle}" \
    "${arguments[@]}" \
    -skipMacroValidation \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 60 \
    test-without-building
    local status="$?"
    set -e
    local elapsed="$(( $(date +%s) - started ))"
    printf 'swift-ci-batch=%s/%s lane=%s suites=%s duration_seconds=%s result_bundle=%s\n' \
        "$((batch + 1))" "${batch_count}" "${lane}" "$#" "${elapsed}" "${result_bundle}"
    return "${status}"
}

if [ "${lane}" = "subprocess" ]; then
    chunk_size=3
    invocation=0
    for ((start = 0; start < ${#selectors[@]}; start += chunk_size)); do
        chunk=("${selectors[@]:start:chunk_size}")
        result_bundle="${result_dir}/swift-subprocess-$((invocation + 1)).xcresult"
        run_invocation "${result_bundle}" "${chunk[@]}" || exit "$?"
        invocation=$((invocation + 1))
    done
else
    result_bundle="${result_dir}/swift-batch-$((batch + 1))-of-${batch_count}.xcresult"
    run_invocation "${result_bundle}" "${selectors[@]}"
fi
