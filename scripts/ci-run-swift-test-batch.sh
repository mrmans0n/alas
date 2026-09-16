#!/usr/bin/env bash
set -euo pipefail

batch="${1:?batch index is required}"
batch_count="${2:?batch count is required}"
lane="${3:-ordinary}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="${repo_root}/.build/xcode/results"
mkdir -p "${result_dir}"

selectors=()
inventory_dir="${SWIFT_TEST_INVENTORY_DIR:-}"
if [ -n "${inventory_dir}" ]; then
    case "${inventory_dir}" in
        /*) ;;
        *) inventory_dir="${repo_root}/${inventory_dir}" ;;
    esac
    inventory_file="${inventory_dir}/${lane}.txt"
    [ -f "${inventory_file}" ] || {
        echo "cached Swift test inventory does not exist: ${inventory_file}" >&2
        exit 1
    }
    if [ "${lane}" = "subprocess" ]; then
        while IFS= read -r suite; do
            [ -n "${suite}" ] || continue
            selectors+=( "-only-testing AlasTests/${suite}" )
        done < "${inventory_file}"
    else
        selector_index=0
        while IFS= read -r suite; do
            [ -n "${suite}" ] || continue
            if [ "$((selector_index % batch_count))" -eq "${batch}" ]; then
                selectors+=( "-only-testing AlasTests/${suite}" )
            fi
            selector_index=$((selector_index + 1))
        done < "${inventory_file}"
    fi
else
    while IFS= read -r selector; do
        selectors+=("${selector}")
    done < <(bash "${repo_root}/scripts/ci-swift-test-inventory.sh" --batch "${batch}" --batch-count "${batch_count}" --lane "${lane}")
fi

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
        if [ "$((invocation % batch_count))" -eq "${batch}" ]; then
            result_bundle="${result_dir}/swift-subprocess-batch-$((batch + 1))-chunk-$((invocation + 1)).xcresult"
            run_invocation "${result_bundle}" "${chunk[@]}" || exit "$?"
        fi
        invocation=$((invocation + 1))
    done
else
    result_bundle="${result_dir}/swift-batch-$((batch + 1))-of-${batch_count}.xcresult"
    run_invocation "${result_bundle}" "${selectors[@]}"
fi
