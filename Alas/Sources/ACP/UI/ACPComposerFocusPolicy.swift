import Foundation

@MainActor
enum ACPComposerFocusPolicy {
    static func focusRequest(
        current: Int,
        oldFirstRunConnecting: Bool,
        newFirstRunConnecting: Bool,
        composerReady: Bool
    ) -> Int {
        guard oldFirstRunConnecting, !newFirstRunConnecting, composerReady else {
            return current
        }
        return current + 1
    }
}
