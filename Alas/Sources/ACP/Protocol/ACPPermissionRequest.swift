import Foundation

/// `session/request_permission` — server-to-client.
///
/// Wire shape per the ACP spec: `toolCall` is a `ToolCallUpdate` (every
/// field optional) — *not* a full `ToolCall`. The original adapter sends
/// only `{ toolCallId, title, rawInput }`. Decoding into the strict
/// `ACPToolCallPayload` failed silently and the user never saw the prompt.
struct ACPPermissionRequestParams: Codable, Equatable {
    let sessionId: String
    let toolCall: ACPPermissionToolCall
    let options: [ACPPermissionOption]
}

/// Lenient toolCall payload used inside permission requests. Mirrors the
/// spec's `ToolCallUpdate` — only `toolCallId` is required.
struct ACPPermissionToolCall: Codable, Equatable {
    let toolCallId: String
    let title: String?
    let kind: String?
    let status: String?
    let content: [ACPContentBlock]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
}

struct ACPPermissionOption: Codable, Equatable, Identifiable, Hashable {
    let optionId: String
    let name: String
    let kind: String        // "allow_once" | "allow_always" | "reject_once" | "reject_always"
    var id: String { optionId }
}

/// Response: `{ outcome: { outcome: "selected", optionId: "..." } }` or
/// `{ outcome: { outcome: "cancelled" } }`.
struct ACPPermissionResponse: Codable, Equatable {
    let outcome: Outcome

    enum Outcome: Codable, Equatable {
        case selected(optionId: String)
        case cancelled

        private enum K: String, CodingKey { case outcome, optionId }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let kind = try c.decode(String.self, forKey: .outcome)
            switch kind {
            case "selected":  self = .selected(optionId: try c.decode(String.self, forKey: .optionId))
            case "cancelled": self = .cancelled
            default:          self = .cancelled
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .selected(let id):
                try c.encode("selected", forKey: .outcome)
                try c.encode(id, forKey: .optionId)
            case .cancelled:
                try c.encode("cancelled", forKey: .outcome)
            }
        }
    }
}
