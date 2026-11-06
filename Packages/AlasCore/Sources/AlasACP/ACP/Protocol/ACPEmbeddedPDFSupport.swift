import Foundation

/// Whether an adapter can take a PDF as an embedded `resource` blob.
///
/// Capabilities cannot answer this: Claude and Codex advertise the same flags,
/// but Codex turns a PDF blob into base64 prompt text. So this gates on identity.
public enum ACPEmbeddedPDFSupport {
    /// The fork's verified release. An unlisted adapter stays refused until it
    /// is verified, because the opposite mistake silently floods the context.
    static let adapterName = "@alas-ide/claude-agent-acp"
    static let minimumVersion = (major: 0, minor: 101, patch: 0, revision: 1)

    public static func supports(
        agentInfo: ACPImplementationInfo?,
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    ) -> Bool {
        guard promptCapabilities.embeddedContext, let agentInfo, agentInfo.name == adapterName else { return false }
        // The prerelease revision is part of the floor, so `SemanticVersion`
        // (which drops it) cannot compare these.
        let parts = agentInfo.version.components(separatedBy: "-alas.")
        guard parts.count == 2, let revision = Int(parts[1]), revision > 0,
              String(revision) == parts[1] else { return false }
        let base = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard base.count == 3 else { return false }
        let numbers = base.compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return false }
        return (numbers[0], numbers[1], numbers[2], revision) >= minimumVersion
    }
}
