import Foundation

public enum PeerDelegationVerb: CaseIterable, Sendable {
    case discover, start, send, read, status, interrupt, outbox

    /// Verbs that begin new work. The rest keep working while access is off,
    /// so running work can finish, be stopped and report back.
    var startsWork: Bool {
        switch self {
        case .discover, .start, .send: true
        case .read, .status, .interrupt, .outbox: false
        }
    }
}

/// The target's consent check for a delegation request.
public enum PeerDelegationGate {
    /// `device` is the one the transport identified for the caller. A device
    /// that never proved its key could be anyone holding a pairing code, so it
    /// gets nothing, not even what keeps working while access is off.
    public static func allows(_ verb: PeerDelegationVerb, device: RemoteDevice?) -> Bool {
        guard let device, device.kind == .alasInstance, isProven(device) else { return false }
        return !verb.startsWork || device.agentAccess != .off
    }

    /// Whether `device` proved the identity it carries.
    public static func isProven(_ device: RemoteDevice) -> Bool {
        device.peerPublicKey?.isEmpty == false && device.peerServerId?.isEmpty == false
    }

    /// The source reports its parent's state and the target only lowers it.
    public static func effectiveAutoRun(parent: Bool, access: RemoteDeviceAgentAccess) -> Bool {
        parent && access == .autoRun
    }
}
