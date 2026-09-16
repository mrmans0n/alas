#!/usr/bin/env bash
set -euo pipefail

batch="${1:?batch index is required}"
batch_count="${2:?batch count is required}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
result_dir="${repo_root}/.build/xcode/results"
result_bundle="${result_dir}/swift-batch-$((batch + 1))-of-${batch_count}.xcresult"
mkdir -p "${result_dir}"

selectors=()
while IFS= read -r selector; do
    selectors+=("${selector}")
done < <(bash "${repo_root}/scripts/ci-swift-test-inventory.sh" --batch "${batch}" --batch-count "${batch_count}")

[ "${#selectors[@]}" -gt 0 ] || {
    echo "batch ${batch} has no assigned suites" >&2
    exit 1
}

arguments=()
for selector in "${selectors[@]}"; do
    arguments+=( -only-testing "${selector#-only-testing }" )
done

started="$(date +%s)"
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
status="$?"
set -e
elapsed="$(( $(date +%s) - started ))"
printf 'swift-ci-batch=%s/%s suites=%s duration_seconds=%s result_bundle=%s\n' \
    "$((batch + 1))" "${batch_count}" "${#selectors[@]}" "${elapsed}" "${result_bundle}"
exit "${status}"
