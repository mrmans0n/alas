import Foundation

public enum ActivityState: String, Sendable, Equatable {
    case busy
    case awaitingInput = "awaiting_input"
    case permissionRequest = "permission_request"
    case idle
    case limited
    /// The last turn ended in an error; cleared by the next turn.
    case failed
}
