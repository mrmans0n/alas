import Foundation

/// Single derivation point for the zmx session name attached to a pane.
/// Used by both `ZmxClient.wrap` (at launch) and `TerminalService.closeSession`
/// (at kill) so the two call sites can never drift.
enum ZmxSessionName {
    static func derive(leafId: String) -> String {
        "alas-\(leafId)"
    }
}
