#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
inventory="${repo_root}/scripts/ci-swift-test-inventory.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

mkdir -p "${sandbox}/AlasTests/Nested"
cat > "${sandbox}/AlasTests/UnitTests.swift" <<'SWIFT'
import Testing

struct UnitTests {
    @Test func ordinary() {}
}

struct HelperTests {}
SWIFT
cat > "${sandbox}/AlasTests/Nested/SecondTests.swift" <<'SWIFT'
import Testing

@Suite(.serialized)
struct SecondTests {
    @Test("works") func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/QuarantinedTests.swift" <<'SWIFT'
import Testing

struct QuarantinedTests {
    @Test func needsExternalService() {}
}
SWIFT
cat > "${sandbox}/AlasTests/InlineSuiteTests.swift" <<'SWIFT'
import Testing

@Suite(.serialized) struct InlineSuiteTests {
    @Test func ordinary() {}
}
SWIFT
printf 'QuarantinedTests\trequires the external fixture; #23\n' > "${sandbox}/quarantine.tsv"

summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate)"
grep -qx 'discovered=4 scheduled=3 quarantined=1' <<<"${summary}"

selectors="$(
    bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" \
        --batch 0 --batch-count 1
)"
grep -qx -- '-only-testing AlasTests/UnitTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/SecondTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineSuiteTests' <<<"${selectors}"
if grep -q 'QuarantinedTests' <<<"${selectors}"; then
    echo 'quarantined suite was scheduled' >&2
    exit 1
fi

printf 'MissingTests\tno longer exists; #23\n' >> "${sandbox}/quarantine.tsv"
if bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate > /dev/null 2>&1; then
    echo 'stale quarantine entry was accepted' >&2
    exit 1
fi

echo "inventory discovers ordinary suites, schedules new suites, and rejects stale quarantine entries"
