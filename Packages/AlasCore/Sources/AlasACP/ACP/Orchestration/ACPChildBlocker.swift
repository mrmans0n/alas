import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// One delegated child stuck on something only a human can resolve. The three
/// detection sources — permission, elicitation/question, and plan — normalize
/// to this so routing, escalation, and copy each handle a single shape.
public struct ACPChildBlocker: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case permission
        case question
        case plan
    }

    public let sessionId: String
    /// Stable for as long as this request is blocked. Forms the outcome ids
    /// and is what the escalation re-check matches against, so it must
    /// identify the request itself, not merely "something is pending".
    public let requestKey: String
    public let kind: Kind
    /// One line naming what is being asked, for the parent's message.
    public let summary: String

    /// Prefixed by id shape so a numeric id and the same digits as a string
    /// can never produce the same key.
    public static func requestKey(_ id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return "n\(value)"
        case .string(let value): return "s\(value)"
        }
    }

    public static func requestKey(_ id: UUID) -> String {
        "u\(id.uuidString)"
    }

    public init(sessionId: String, requestKey: String, kind: Kind, summary: String) {
        self.sessionId = sessionId
        self.requestKey = requestKey
        self.kind = kind
        self.summary = summary
    }
}
