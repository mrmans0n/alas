import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// How long a session-start request asks the adapter to wait for the MCP
/// servers Alas requested, so the first prompt can see their tools.
///
/// Only codex-acp honors this today (`_meta.mcpStartupAwaitTimeoutMs`,
/// experimental since 2.0.0, verified against 2.2.2-alas.1). On session/new,
/// session/resume, and session/fork the adapter waits until every requested
/// server is ready, failed, or cancelled, or until the timeout, whichever comes
/// first. It never cancels the startup and never fails the request because a
/// server failed: it still reports each failed or cancelled server afterwards as
/// a failed `mcp__<server>__startup` tool call (not on forks). A returned
/// request therefore says nothing about which servers succeeded; Alas keeps
/// tracking its own MCP server through registration and hello.
///
/// session/load never waits and ignores the field, so Alas omits it there. A
/// requested server whose name the user's Codex config already defines is not
/// started; Codex runs its own entry, the wait skips that name, and the adapter
/// reports it as not started.
public enum ACPMCPStartupWaitPolicy {
    public static let timeoutMilliseconds = 3000
    /// The first codex-acp release that honors the field.
    static let minimumCodexVersion = SemanticVersion(major: 2, minor: 0, patch: 0)

    /// The wait for the adapter that answered `initialize`, or nil when it is
    /// not a verified codex-acp release that supports it.
    public static func timeoutMilliseconds(for agentInfo: ACPImplementationInfo?) -> Int? {
        guard let agentInfo,
              ACPManagedAdapterDescriptor.codex.verifiedPackageNames.contains(agentInfo.name),
              let version = SemanticVersion(parsing: agentInfo.version),
              version >= minimumCodexVersion
        else { return nil }
        return timeoutMilliseconds
    }
}
