import Foundation
import CryptoKit

/// Single derivation point for the zmx session name attached to a pane.
/// Used by both `ZmxClient.wrap` (at launch) and `TerminalService.closeSession`
/// (at kill) so the two call sites can never drift.
enum ZmxSessionName {
    /// Decoded parts of a scoped session name (`alas-<wtHash>-<leafHash>`).
    /// Returned by `parseScoped`; legacy `alas-<leafId>` names produce nil.
    struct Parsed: Equatable {
        let worktreeIdHash: String
        let leafIdHash: String
    }

    static func derive(worktreeId: String, leafId: String) -> String {
        "alas-\(hash16(worktreeId))-\(hash16(leafId))"
    }

    /// Worktree owners retain their exact historical name. Checkout owners
    /// include their durable UUID and a hash of the execution location, so a
    /// local checkout and a same-path checkout on SSH cannot collide.
    static func derive(owner: SessionOwnerID, leafId: String) -> String {
        switch owner {
        case .worktree(let worktreeID):
            derive(worktreeId: worktreeID, leafId: leafId)
        case .workspaceCheckout(let checkoutID, let location):
            "alas-workspace-\(checkoutID.uuidString.lowercased())-\(hash16(location.identityComponent))-\(hash16(leafId))"
        }
    }

    static func legacy(leafId: String) -> String {
        "alas-\(leafId)"
    }

    /// Split a scoped session name into its (wt, leaf) hash halves. Returns
    /// nil for legacy `alas-<UUID>` shapes (the leafId contains dashes, so
    /// the segment count differs) and for any string that doesn't match the
    /// 3-segment `alas-<16hex>-<16hex>` form.
    static func parseScoped(_ name: String) -> Parsed? {
        let parts = name.split(separator: "-")
        guard parts.count == 3, parts[0] == "alas",
              parts[1].count == 16, parts[2].count == 16,
              parts[1].allSatisfy(\.isHexDigit), parts[2].allSatisfy(\.isHexDigit)
        else { return nil }
        return Parsed(worktreeIdHash: String(parts[1]), leafIdHash: String(parts[2]))
    }

    /// Same hash the `derive` call uses for each id-half. Exposed so callers
    /// computing membership sets (e.g. the boot-time orphan sweep) can map
    /// known worktree ids and leaf ids into hash space without re-implementing
    /// the SHA256-prefix trick.
    static func hash16(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
