import Foundation

struct HookEvent: Codable, Equatable {
    let sessionId: String
    let kind: String      // "stop" | "awaiting"
    let timestamp: Date
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case kind
        case timestamp
        case summary
    }
}

extension HookEvent {
    static func decode(_ data: Data) throws -> HookEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HookEvent.self, from: data)
    }
}
