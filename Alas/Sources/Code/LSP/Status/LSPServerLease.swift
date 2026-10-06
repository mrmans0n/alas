import Foundation

enum LSPServerUnavailableReason: String, Sendable {
    case notInstalled
    case disabled
    case blockedByGatekeeper
}

enum LSPServerRetainResult {
    case serving(LSPServerLease)
    case unavailable(language: String, reason: LSPServerUnavailableReason)
}

/// Keeps a language server running while a pane shows it, without opening a
/// document. Release explicitly, or let deinit release it.
@MainActor
final class LSPServerLease {
    let status: LSPServerStatus
    private var onRelease: (@MainActor () -> Void)?

    init(status: LSPServerStatus, onRelease: @escaping @MainActor () -> Void) {
        self.status = status
        self.onRelease = onRelease
    }

    func release() {
        let release = onRelease
        onRelease = nil
        release?()
    }

    isolated deinit {
        release()
    }
}
