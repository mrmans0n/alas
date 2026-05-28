import Foundation
import CryptoKit

/// Single derivation point for the zmx session name attached to a pane.
/// Used by both `ZmxClient.wrap` (at launch) and `TerminalService.closeSession`
/// (at kill) so the two call sites can never drift.
enum ZmxSessionName {
    static func derive(worktreeId: String, leafId: String) -> String {
        "alas-\(hash16(worktreeId))-\(hash16(leafId))"
    }

    private static func hash16(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
