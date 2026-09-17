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
cat > "${sandbox}/AlasTests/GlobalBehavior.swift" <<'SWIFT'
import Testing

@Test func globalBehavior() {}
SWIFT
cat > "${sandbox}/AlasTests/GlobalProcessBehavior.swift" <<'SWIFT'
import Foundation
import Testing

@Test func globalProcessBehavior() {
    _ = Process()
}
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
cat > "${sandbox}/AlasTests/JSONRPCStdioFixtureTests.swift" <<'SWIFT'
import Foundation
import Testing

struct JSONRPCStdioFixtureTests {
    @Test func runsStdioTransport() {
        _ = JSONRPCStdioTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [],
            environment: nil
        )
    }
}
SWIFT
cat > "${sandbox}/AlasTests/LSPTransportFixtureTests.swift" <<'SWIFT'
import Foundation
import Testing

struct LSPTransportFixtureTests {
    @Test func runsLSPTransport() {
        _ = LSPTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: nil)
    }
}
SWIFT
cat > "${sandbox}/AlasTests/ACPStdioClientFixtureTests.swift" <<'SWIFT'
import Foundation
import Testing

struct ACPStdioClientFixtureTests {
    @Test func runsExecutableBackedClient() {
        _ = ACPStdioClient(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [], environment: nil)
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
cat > "${sandbox}/AlasTests/RawStringTests.swift" <<'SWIFT'
import Testing

@Suite(#"He said "go)" now"#) struct RawStringTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/LSPInstallerTests.swift" <<'SWIFT'
import Testing

struct LSPInstallerTests {
    @Test func installsThroughProductionWrapper() {}
}
SWIFT
cat > "${sandbox}/AlasTests/SelfUpdaterTests.swift" <<'SWIFT'
import Testing

struct SelfUpdaterTests {
    @Test func updatesThroughProductionWrapper() {}
}
SWIFT
cat > "${sandbox}/AlasTests/AgentRunnerInvocationTests.swift" <<'SWIFT'
import Testing

struct AgentRunnerInvocationTests {
    @Test func invokesAgentRunnerWrapper() {}
}
SWIFT
cat > "${sandbox}/AlasTests/MultilineStringTests.swift" <<'SWIFT'
import Testing

@Suite("""
A "quoted ) text"
""") struct MultilineStringTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/EscapedDelimiterTests.swift" <<'SWIFT'
import Testing

@Suite("""
A literal delimiter: \"""
""") struct EscapedDelimiterTests {
    @Test func ordinary() {}
}
SWIFT
cat > "${sandbox}/AlasTests/NestedIndentedSuite.swift" <<'SWIFT'
import Testing

enum ParserNamespace {
    @Suite
    struct ParserTests {
        @Test func ordinary() {}
    }
}
SWIFT
cat > "${sandbox}/AlasTests/AllmanNamespaceSuite.swift" <<'SWIFT'
import Testing

enum AllmanNamespace
{
    @Suite
    struct AllmanParserTests
    {
        @Test func ordinary() {}
    }
}
SWIFT
cat > "${sandbox}/AlasTests/ExtensionNamespaceSuite.swift" <<'SWIFT'
import Testing

extension ExtensionNamespace {
    @Suite
    struct ExtensionParserTests {
        @Test func ordinary() {}
    }
}
SWIFT
cat > "${sandbox}/AlasTests/NestedSuiteRestoreTests.swift" <<'SWIFT'
import Testing

struct OuterTests {
    struct InnerTests {
        @Test func inner() {}
    }

    @Test func outer() {}
}
SWIFT
cat > "${sandbox}/AlasTests/BraceScopeTests.swift" <<'SWIFT'
import Testing

struct BraceOwnerTests {
    @Test func malformedJsonIsUnknown() {
        _ = "not json {{"
    }
}

struct FollowingTopLevelTests {
    @Test func ordinary() {}
}
SWIFT
printf 'QuarantinedTests\trequires the external fixture; #23\n' > "${sandbox}/quarantine.tsv"

summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate)"
grep -qx 'discovered=38 scheduled=37 ordinary=20 subprocess=17 quarantined=1' <<<"${summary}"

inventory_cache="${sandbox}/inventory-cache"
cached_summary="$(bash "${inventory}" --root "${sandbox}/AlasTests" --quarantine "${sandbox}/quarantine.tsv" --validate --write-dir "${inventory_cache}")"
grep -qx "${summary}" <<<"${cached_summary}"
grep -qx 'AgentRunnerInvocationTests' "${inventory_cache}/subprocess.txt"
grep -qx 'ACPStdioClientFixtureTests' "${inventory_cache}/subprocess.txt"
grep -qx 'AllmanNamespace.AllmanParserTests' "${inventory_cache}/ordinary.txt"
grep -qx 'BraceOwnerTests' "${inventory_cache}/ordinary.txt"
grep -qx 'CommentAttributeTests' "${inventory_cache}/ordinary.txt"
grep -qx 'EscapedDelimiterTests' "${inventory_cache}/ordinary.txt"
grep -qx 'ExtensionNamespace.ExtensionParserTests' "${inventory_cache}/ordinary.txt"
grep -qx 'FollowingTopLevelTests' "${inventory_cache}/ordinary.txt"
grep -qx 'globalBehavior' "${inventory_cache}/ordinary.txt"
grep -qx 'globalProcessBehavior' "${inventory_cache}/subprocess.txt"
grep -qx 'InlineNamedSuiteTests' "${inventory_cache}/ordinary.txt"
grep -qx 'InlineNestedAttributeTests' "${inventory_cache}/subprocess.txt"
grep -qx 'MultilineAttributeTests' "${inventory_cache}/ordinary.txt"
grep -qx 'MultilineStringTests' "${inventory_cache}/ordinary.txt"
grep -qx 'NestedCommentTests' "${inventory_cache}/ordinary.txt"
grep -qx 'OuterTests' "${inventory_cache}/ordinary.txt"
grep -qx 'OuterTests.InnerTests' "${inventory_cache}/ordinary.txt"
grep -qx 'ParserNamespace.ParserTests' "${inventory_cache}/ordinary.txt"
grep -qx 'RawStringTests' "${inventory_cache}/ordinary.txt"
grep -qx 'RuntimeBehaviorTests' "${inventory_cache}/subprocess.txt"
grep -qx 'JSONRPCStdioFixtureTests' "${inventory_cache}/subprocess.txt"
grep -qx 'LSPInstallerTests' "${inventory_cache}/subprocess.txt"
grep -qx 'LSPTransportFixtureTests' "${inventory_cache}/subprocess.txt"
grep -qx 'SelfUpdaterTests' "${inventory_cache}/subprocess.txt"
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
grep -qx -- '-only-testing AlasTests/AllmanNamespace.AllmanParserTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/BraceOwnerTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/CommentAttributeTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/EscapedDelimiterTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/ExtensionNamespace.ExtensionParserTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/FollowingTopLevelTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/globalBehavior' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/SecondTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/InlineNamedSuiteTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/MultilineAttributeTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/MultilineStringTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/NestedCommentTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/OuterTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/OuterTests.InnerTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/ParserNamespace.ParserTests' <<<"${selectors}"
grep -qx -- '-only-testing AlasTests/RawStringTests' <<<"${selectors}"
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
if grep -q 'globalProcessBehavior' <<<"${selectors}"; then
    echo 'free-standing subprocess test was scheduled with ordinary suites' >&2
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
if grep -Eq 'LSPInstallerTests|SelfUpdaterTests|AgentRunnerInvocationTests' <<<"${selectors}"; then
    echo 'production-wrapper subprocess suite was scheduled with ordinary suites' >&2
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
grep -qx -- '-only-testing AlasTests/AgentRunnerInvocationTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/ACPStdioClientFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/JSONRPCStdioFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/globalProcessBehavior' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/LSPInstallerTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/LSPTransportFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/ProcessFixtureTests' <<<"${subprocess_selectors}"
grep -qx -- '-only-testing AlasTests/SelfUpdaterTests' <<<"${subprocess_selectors}"
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
grep -qx -- 'AlasTests/AllmanNamespace.AllmanParserTests' "${ordinary_log}"
grep -qx -- 'AlasTests/CommentAttributeTests' "${ordinary_log}"
grep -qx -- 'AlasTests/ExtensionNamespace.ExtensionParserTests' "${ordinary_log}"
grep -qx -- 'AlasTests/InlineNamedSuiteTests' "${ordinary_log}"
grep -qx -- 'AlasTests/MultilineAttributeTests' "${ordinary_log}"
grep -qx -- 'AlasTests/NestedCommentTests' "${ordinary_log}"
grep -qx -- 'AlasTests/OuterTests.InnerTests' "${ordinary_log}"
grep -qx -- 'AlasTests/RawStringTests' "${ordinary_log}"
grep -qx -- 'AlasTests/SplitDeclarationTests' "${ordinary_log}"
grep -qx -- 'AlasTests/UnitTests' "${ordinary_log}"
if grep -q 'AlasTests/InlineNestedAttributeTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/BraceOwnerTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/EscapedDelimiterTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/FollowingTopLevelTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/globalBehavior' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/InlineSuiteTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/MultilineStringTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/OuterTests$' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/ParserNamespace.ParserTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/SecondTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi
if grep -q 'AlasTests/StringParenSuiteTests' "${ordinary_log}"; then
    echo 'cached ordinary batch used the wrong modulo assignment' >&2
    exit 1
fi

subprocess_log="${sandbox}/subprocess-xcodebuild.log"
env PATH="${sandbox}/bin:${PATH}" XCODEBUILD_LOG="${subprocess_log}" SWIFT_TEST_INVENTORY_DIR="${inventory_cache}" \
    bash "${batch_runner}" 0 1 subprocess
grep -qx -- 'AlasTests/AgentRunnerInvocationTests' "${subprocess_log}"
grep -qx -- 'AlasTests/ACPStdioClientFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/BehaviorFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/BeautifulMermaidFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/InlineNestedAttributeTests' "${subprocess_log}"
grep -qx -- 'AlasTests/JSONRPCStdioFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/globalProcessBehavior' "${subprocess_log}"
grep -qx -- 'AlasTests/LSPInstallerTests' "${subprocess_log}"
grep -qx -- 'AlasTests/LSPTransportFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/ProcessFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/RunScriptFixtureTests' "${subprocess_log}"
grep -qx -- 'AlasTests/RuntimeBehaviorTests' "${subprocess_log}"
grep -qx -- 'AlasTests/SelfUpdaterTests' "${subprocess_log}"
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
