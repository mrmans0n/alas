// Alas/Sources/Harness/AgentHookEvent.swift
import Foundation

enum ActivityEvent: String, Sendable {
    case busy
    case awaitingInput = "awaiting_input"
    case permissionRequest = "permission_request"
    case idle
    case attached
    case detached
}

enum ActivityState: String, Sendable, Equatable {
    case busy
    case awaitingInput = "awaiting_input"
    case permissionRequest = "permission_request"
    case idle
}

struct AgentHookEvent: Equatable, Sendable {
    let version: Int
    let event: ActivityEvent
    let agent: AgentKind
    let sessionId: String
    let pid: pid_t?
    let timestamp: Date?
    let body: String?
}

extension AgentHookEvent {
    static func decode(from data: Data) throws -> AgentHookEvent {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json else {
            throw AgentHookEventError.malformed("Not a JSON object")
        }
        guard let v = json["v"] as? Int else {
            throw AgentHookEventError.malformed("Missing 'v'")
        }
        guard let eventStr = json["event"] as? String else {
            throw AgentHookEventError.malformed("Missing 'event'")
        }
        guard let event = AgentLifecycleEventMapper.map(eventStr) else {
            throw AgentHookEventError.unknownEvent(eventStr)
        }
        guard let agentStr = json["agent"] as? String else {
            throw AgentHookEventError.malformed("Missing 'agent'")
        }
        guard let agent = AgentKind(rawValue: agentStr) else {
            throw AgentHookEventError.malformed("Unknown agent '\(agentStr)'")
        }
        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            throw AgentHookEventError.malformed("Missing 'session_id'")
        }
        let pid: pid_t? = (json["pid"] as? Int).flatMap { $0 > 0 ? pid_t(exactly: $0) : nil }
        let ts: Date? = (json["ts"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        let body = json["body"] as? String
        return AgentHookEvent(
            version: v, event: event, agent: agent,
            sessionId: sessionId, pid: pid, timestamp: ts, body: body
        )
    }
}

enum AgentHookEventError: Error, Equatable {
    case malformed(String)
    case unknownEvent(String)
}
