import Foundation

/// One delegated child stuck on something only a human can resolve. The three
/// detection sources — permission, elicitation/question, and plan — normalize
/// to this so routing, escalation, and copy each handle a single shape.
struct ACPChildBlocker: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case permission
        case question
        case plan
    }

    let sessionId: String
    /// Stable for as long as this request is blocked. Forms the outcome ids
    /// and is what the escalation re-check matches against, so it must
    /// identify the request itself, not merely "something is pending".
    let requestKey: String
    let kind: Kind
    /// One line naming what is being asked, for the parent's message.
    let summary: String

    /// Prefixed by id shape so a numeric id and the same digits as a string
    /// can never produce the same key.
    static func requestKey(_ id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return "n\(value)"
        case .string(let value): return "s\(value)"
        }
    }

    static func requestKey(_ id: UUID) -> String {
        "u\(id.uuidString)"
    }
}
