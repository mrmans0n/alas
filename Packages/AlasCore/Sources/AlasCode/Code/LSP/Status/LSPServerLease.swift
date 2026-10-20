import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum LSPServerUnavailableReason: String, Sendable {
    case notInstalled
    case disabled
    case blockedByGatekeeper
}

public enum LSPServerRetainResult: Sendable {
    case serving(LSPServerLease)
    case unavailable(language: String, reason: LSPServerUnavailableReason)
}

/// Keeps a language server running while a pane shows it, without opening a
/// document. Release explicitly, or let deinit release it.
@MainActor
public final class LSPServerLease {
    nonisolated public let status: LSPServerStatus
    private var onRelease: (@MainActor () -> Void)?

    public init(status: LSPServerStatus, onRelease: @escaping @MainActor () -> Void) {
        self.status = status
        self.onRelease = onRelease
    }

    public func release() {
        let release = onRelease
        onRelease = nil
        release?()
    }

    isolated deinit {
        release()
    }
}
