import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Whether an accepted URL elicitation's wait closes when the prompt it
/// arrived under ends.
///
/// codex-acp 2.9.0 stopped sending `elicitation/complete` for a URL
/// elicitation forwarded from Codex (agentclientprotocol/codex-acp#787): the
/// Codex request resolving, or the app-server exiting, is no evidence that the
/// external flow finished. Such a wait would stay open until the user
/// dismissed it, so its turn ending closes it instead. The adapter's own MCP
/// sign-in still sends `elicitation/complete`: within the turn of the `/mcp`
/// command that started it, or outside any prompt when the session starts.
///
/// Other adapters keep their waits until `elicitation/complete`: the MCP
/// sign-in claude-agent-acp starts after a `/mcp` reconnect completes in the
/// background, after the command's turn ended.
public enum ACPURLElicitationWaitPolicy {
    /// The first codex-acp release that omits `elicitation/complete`.
    static let minimumCodexVersion = SemanticVersion(major: 2, minor: 9, patch: 0)

    public static func closesWithTurn(agentInfo: ACPImplementationInfo?) -> Bool {
        guard let agentInfo,
              ACPManagedAdapterDescriptor.codex.verifiedPackageNames.contains(agentInfo.name),
              let version = SemanticVersion(parsing: agentInfo.version)
        else { return false }
        return version >= minimumCodexVersion
    }
}
