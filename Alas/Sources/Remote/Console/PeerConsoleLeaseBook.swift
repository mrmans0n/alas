import Foundation

/// Host-side control leases for peer consoles. Alas, not zmx, decides who
/// may type: the host's zmx client stays leader and geometry owner, and
/// accepted peer input reaches the PTY through zmx `Send`.
///
/// Each console is held by the host or by exactly one attachment. Every
/// ownership change bumps the console's generation, so input stamped with
/// an older generation is rejected even if it arrives after a reclaim.
struct PeerConsoleLeaseBook {
    private var holders: [String: String] = [:]
    private var generations: [String: Int] = [:]

    func holder(of consoleId: String) -> String? { holders[consoleId] }
    func generation(of consoleId: String) -> Int { generations[consoleId, default: 0] }

    /// Grants control to `attachmentId`, or returns nil when another
    /// attachment holds it. Idempotent for the current holder.
    mutating func take(_ consoleId: String, by attachmentId: String) -> Int? {
        switch holders[consoleId] {
        case attachmentId?: return generation(of: consoleId)
        case .some: return nil
        case nil:
            holders[consoleId] = attachmentId
            return bump(consoleId)
        }
    }

    /// Returns control to the host if `attachmentId` holds it; covers
    /// release, detach, disconnect, revocation, and target exit.
    mutating func release(_ consoleId: String, by attachmentId: String) -> Int? {
        guard holders[consoleId] == attachmentId else { return nil }
        holders[consoleId] = nil
        return bump(consoleId)
    }

    /// Host reclaim: invalidates the holder's generation before the host's
    /// own input is restored. Returns the revoked attachment.
    mutating func reclaim(_ consoleId: String) -> (attachmentId: String, generation: Int)? {
        guard let holder = holders.removeValue(forKey: consoleId) else { return nil }
        return (holder, bump(consoleId))
    }

    func accepts(_ consoleId: String, from attachmentId: String, generation: Int) -> Bool {
        holders[consoleId] == attachmentId && generations[consoleId] == generation
    }

    private mutating func bump(_ consoleId: String) -> Int {
        let next = generation(of: consoleId) + 1
        generations[consoleId] = next
        return next
    }
}
