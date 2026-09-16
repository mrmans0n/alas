#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
inventory="${repo_root}/scripts/ci-swift-test-inventory.sh"
batch_runner="${repo_root}/scripts/ci-run-swift-test-batch.sh"
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
cat > "${sandbox}/AlasTests/ProcessFixtureTests.swift" <<'SWIFT'
import Testing

struct ProcessFixtureTests {
    @Test func runsChildProcess() {}
}
SWIFT
cat > "${sandbox}/AlasTests/BehaviorFixtureTests.swift" <<'SWIFT'
import Foundation
import Testing

struct BehaviorFixtureTests {
    @Test func runsChildProcess() {
        _ = Process()
    }
}
SWIFT
cat > "${sandbox}/AlasTests/WrapperFixtureTests.swift" <<'SWIFT'
import Testing

struct WrapperFixtureTests {
    @Test func runsChildProcess() {
        _ = ProcessFixtureRunner.launch()
    }
}
SWIFT
cat > "${sandbox}/AlasTests/SharedGitFixtureTests.swift" <<'SWIFT'
import Testing

struct SharedGitFixtureTests {
    @Test func usesSharedRepositoryHelper() {
        _ = CheckpointTestRepository.make()
    }
}
SWIFT
cat > "${sandbox}/AlasTests/RunScriptFixtureTests.swift" <<'SWIFT'
import Testing

struct RunScriptFixtureTests {
    @Test func detectsRuntimeMarkers() {}
}
SWIFT
cat > "${sandbox}/AlasTests/BeautifulMermaidFixtureTests.swift" <<'SWIFT'
import Testing

struct BeautifulMermaidFixtureTests {
    @Test func rendersNativeDiagram() {}
}
SWIFT
cat > "${sandbox}/AlasTests/WorkspaceEditExecutorFixtureTests.swift" <<'SWIFT'
import Testing

struct WorkspaceEditExecutorFixtureTests {
    @Test func isolatesBufferMutationRace() {}
}
SWIFT
cat > "${sandbox}/AlasTests/InlineSuiteTests.swift" <<'SWIFT'
import Testing

@Suite(.serialized) struct InlineSuiteTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/InlineNamedSuiteTests.swift" <<'SWIFT'
import Testing

@Suite("Inline suite") struct InlineNamedSuiteTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/InlineNestedAttributeTests.swift" <<'SWIFT'
import Testing

@Suite(.disabled(if: false)) struct InlineNestedAttributeTests {
    @Test func ordinary() {}
}
SWIFT
printf 'QuarantinedTests\trequires the external fixture; #23\n' > "${sandbox}/quarantine.tsv"

summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate)"
grep -qx 'discovered=13 scheduled=12 ordinary=5 subprocess=7 quarantined=1' <<<"${summary}"

inventory_cache="${sandbox}/inventory-cache"
cached_summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate --write-dir "${inventory_cache}")"
grep -qx "${summary}" <<<"${cached_summary}"
grep -qx 'InlineNamedSuiteTests' "${inventory_cache}/ordinary.txt"
grep -qx 'InlineNestedAttributeTests' "${inventory_cache}/ordinary.txt"
grep -qx 'BehaviorFixtureTests' "${inventory_cache}/subprocess.txt"
grep -qx 'QuarantinedTests' "${inventory_cache}/quarantined.txt"

selectors="$(
    bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" \
        --batch 0 --batch-count 1
)"
grep -qx -- '-only-testing AlasTests/UnitTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/SecondTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineNamedSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineNestedAttributeTests' <<<"${selectors}"
if grep -q 'QuarantinedTests' <<<"${selectors}"; then
    echo 'quarantined suite was scheduled' >&2
    exit 1
fi
if grep -q 'ProcessFixtureTests' <<<"${selectors}"; then
    echo 'subprocess suite was scheduled with ordinary suites' >&2
    exit 1
fi
if grep -q 'BehaviorFixtureTests' <<<"${selectors}"; then
    echo 'behavior-detected subprocess suite was scheduled with ordinary suites' >&2
    exit 1
fi
if grep -q 'WrapperFixtureTests' <<<"${selectors}"; then
    echo 'process-wrapper suite was scheduled with ordinary suites' >&2
    exit 1
fi
if grep -q 'BeautifulMermaidFixtureTests' <<<"${selectors}"; then
    echo 'native Mermaid suite was scheduled with ordinary suites' >&2
    exit 1
fi

subprocess_selectors="$(
    bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" \
        --batch 0 --batch-count 1 --lane subprocess
)"
grep -qx -- '-only-testing AlasTests/ProcessFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/BehaviorFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/BeautifulMermaidFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/WrapperFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/RunScriptFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/SharedGitFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/WorkspaceEditExecutorFixtureTests' <<<"${subprocess_selectors}"

mkdir -p "${sandbox}/bin"
cat > "${sandbox}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${XCODEBUILD_LOG:?}"
SH
chmod +x "${sandbox}/bin/xcodebuild"

ordinary_log="${sandbox}/ordinary-xcodebuild.log"
env PATH="${sandbox}/bin:${PATH}" XCODEBUILD_LOG="${ordinary_log}" SWIFT_TEST_INVENTORY_DIR="${inventory_cache}" \
    bash "${batch_runner}" 0 2
grep -qx -- '-only-testing' "${ordinary_log}"
grep -qx -- 'AlasTests/InlineNamedSuiteTests' "${ordinary_log}"
grep -qx -- 'AlasTests/InlineSuiteTests' "${ordinary_log}"
grep -qx -- 'AlasTests/UnitTests' "${ordinary_log}"
if grep -q 'AlasTests/InlineNestedAttributeTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/SecondTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi

subprocess_log="${sandbox}/subprocess-xcodebuild.log"
env PATH="${sandbox}/bin:${PATH}" XCODEBUILD_LOG="${subprocess_log}" SWIFT_TEST_INVENTORY_DIR="${inventory_cache}" \
    bash "${batch_runner}" 0 1 subprocess
grep -qx -- 'AlasTests/BehaviorFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/BeautifulMermaidFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/ProcessFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/RunScriptFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/SharedGitFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/WrapperFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/WorkspaceEditExecutorFixtureTests' "${subprocess_log}"

printf 'MissingTests\tno longer exists; #23\n' >> "${sandbox}/quarantine.tsv"
if bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate > /dev/null 2>&1; then
    echo 'stale quarantine entry was accepted' >&2
    exit 1
fi

echo "inventory discovers ordinary suites, schedules new suites, and rejects stale quarantine entries"
