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
    @Test func launchesProcess() {
        _ = Process()
    }
}
SWIFT
cat > "${sandbox}/AlasTests/StringParenSuiteTests.swift" <<'SWIFT'
import Testing

@Suite("Parser (") struct StringParenSuiteTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/MultilineAttributeTests.swift" <<'SWIFT'
import Testing

@Suite(
    .serialized
) struct MultilineAttributeTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/RuntimeBehaviorTests.swift" <<'SWIFT'
import Foundation
import Testing

@Suite(
    .serialized
) struct RuntimeBehaviorTests {
    @Test func launchesProcess() {
        _ = Process()
    }
}
SWIFT
cat > "${sandbox}/AlasTests/CommentAttributeTests.swift" <<'SWIFT'
import Testing

@Suite( // rationale mentions ) here
    /* block comment mentions ) too */
    .serialized
) struct CommentAttributeTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/NestedCommentTests.swift" <<'SWIFT'
import Testing

@Suite(
    /* outer comment starts
       /* inner comment mentions ) */
       outer comment still mentions ) here
    */
    .serialized
) struct NestedCommentTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/SplitDeclarationTests.swift" <<'SWIFT'
struct SplitDeclarationTests {}
SWIFT
cat > "${sandbox}/AlasTests/SplitDeclarationTests+Tests.swift" <<'SWIFT'
import Testing

extension SplitDeclarationTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/SplitRuntimeTests.swift" <<'SWIFT'
struct SplitRuntimeTests {}
SWIFT
cat > "${sandbox}/AlasTests/SplitRuntimeTests+Tests.swift" <<'SWIFT'
import Foundation
import Testing

extension SplitRuntimeTests {
    @Test func launchesProcess() {
        _ = Process()
    }
}
SWIFT
printf 'QuarantinedTests\trequires the external fixture; #23\n' > "${sandbox}/quarantine.tsv"

summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate)"
grep -qx 'discovered=20 scheduled=19 ordinary=9 subprocess=10 quarantined=1' <<<"${summary}"

inventory_cache="${sandbox}/inventory-cache"
cached_summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate --write-dir "${inventory_cache}")"
grep -qx "${summary}" <<<"${cached_summary}"
grep -qx 'CommentAttributeTests' "${inventory_cache}/ordinary.txt"
grep -qx 'InlineNamedSuiteTests' "${inventory_cache}/ordinary.txt"
grep -qx 'InlineNestedAttributeTests' "${inventory_cache}/subprocess.txt"
grep -qx 'MultilineAttributeTests' "${inventory_cache}/ordinary.txt"
grep -qx 'NestedCommentTests' "${inventory_cache}/ordinary.txt"
grep -qx 'RuntimeBehaviorTests' "${inventory_cache}/subprocess.txt"
grep -qx 'SplitDeclarationTests' "${inventory_cache}/ordinary.txt"
grep -qx 'SplitRuntimeTests' "${inventory_cache}/subprocess.txt"
grep -qx 'StringParenSuiteTests' "${inventory_cache}/ordinary.txt"
grep -qx 'BehaviorFixtureTests' "${inventory_cache}/subprocess.txt"
grep -qx 'QuarantinedTests' "${inventory_cache}/quarantined.txt"

source_only="${sandbox}/SourceOnlyTests"
mkdir -p "${source_only}"
cat > "${source_only}/BehaviorOnlyTests.swift" <<'SWIFT'
import Foundation
import Testing

struct BehaviorOnlyTests {
    @Test func launchesProcess() {
        _ = Process()
    }
}
SWIFT
empty_quarantine="${sandbox}/empty-quarantine.tsv"
: > "${empty_quarantine}"
source_only_summary="$(bash "${inventory}" --root "${source_only}" --quarantine "${empty_quarantine}" --validate)"
grep -qx 'discovered=1 scheduled=1 ordinary=0 subprocess=1 quarantined=0' <<<"${source_only_summary}"

selectors="$(
    bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" \
        --batch 0 --batch-count 1
)"
grep -qx -- '-only-testing AlasTests/UnitTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/CommentAttributeTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/SecondTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineNamedSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/MultilineAttributeTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/NestedCommentTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/SplitDeclarationTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/StringParenSuiteTests' <<<"${selectors}"
if grep -q 'InlineNestedAttributeTests' <<<"${selectors}"; then
    echo 'nested subprocess suite was scheduled with ordinary suites' >&2
    exit 1
fi
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
if grep -q 'RuntimeBehaviorTests' <<<"${selectors}"; then
    echo 'multiline behavior-detected subprocess suite was scheduled with ordinary suites' >&2
    exit 1
fi
if grep -q 'SplitRuntimeTests' <<<"${selectors}"; then
    echo 'split-file subprocess suite was scheduled with ordinary suites' >&2
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
grep -qx -- '-only-testing AlasTests/InlineNestedAttributeTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/WrapperFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/RuntimeBehaviorTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/SplitRuntimeTests' <<<"${subprocess_selectors}"
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
grep -qx -- 'AlasTests/CommentAttributeTests' "${ordinary_log}"
grep -qx -- 'AlasTests/InlineSuiteTests' "${ordinary_log}"
grep -qx -- 'AlasTests/NestedCommentTests' "${ordinary_log}"
grep -qx -- 'AlasTests/SplitDeclarationTests' "${ordinary_log}"
grep -qx -- 'AlasTests/UnitTests' "${ordinary_log}"
if grep -q 'AlasTests/InlineNestedAttributeTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/InlineNamedSuiteTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi

subprocess_log="${sandbox}/subprocess-xcodebuild.log"
env PATH="${sandbox}/bin:${PATH}" XCODEBUILD_LOG="${subprocess_log}" SWIFT_TEST_INVENTORY_DIR="${inventory_cache}" \
    bash "${batch_runner}" 0 1 subprocess
grep -qx -- 'AlasTests/BehaviorFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/BeautifulMermaidFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/InlineNestedAttributeTests' "${subprocess_log}"
grep -qx -- 'AlasTests/ProcessFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/RunScriptFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/RuntimeBehaviorTests' "${subprocess_log}"
grep -qx -- 'AlasTests/SharedGitFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/SplitRuntimeTests' "${subprocess_log}"
grep -qx -- 'AlasTests/WrapperFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/WorkspaceEditExecutorFixtureTests' "${subprocess_log}"

printf 'MissingTests\tno longer exists; #23\n' >> "${sandbox}/quarantine.tsv"
if bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate > /dev/null 2>&1; then
    echo 'stale quarantine entry was accepted' >&2
    exit 1
fi

echo "inventory discovers ordinary suites, schedules new suites, and rejects stale quarantine entries"
