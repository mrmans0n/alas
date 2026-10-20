import CryptoKit
import Foundation
import AlasFoundation

public enum MCPAttachmentSkipReason: Equatable, Sendable {
    case unsupportedTransport
    case missingVariable(String)
    case invalidConfiguration(String)
    /// A checkout snapshot retains the descriptor for diagnostics, but never
    /// retargets it to whichever member currently has focus.
    case unavailableMember
    /// Repo-defined server the user has not approved.
    case repoNotApproved
    /// Repo-defined server the user explicitly declined, kept distinct so the
    /// status control can offer a way to reconsider it.
    case repoDeclined
    /// Repo-defined server the user disabled for this project.
    case repoDisabled
    /// The SSH host cannot relay the built-in visual tool (e.g. an outdated
    /// helper or lost session ownership).
    case remoteRelayUnavailable(String)
}
