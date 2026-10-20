// Alas/Sources/Harness/AgentHookEvent.swift
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ActivityEvent: String, Sendable {
    case busy
    case backgroundStarted = "background_started"
    case backgroundEnded = "background_ended"
    case awaitingInput = "awaiting_input"
    case permissionRequest = "permission_request"
    case idle
    case attached
    case detached
}

public struct AgentHookEvent: Equatable, Sendable {
    public let version: Int
    public let event: ActivityEvent
    public let agent: AgentKind
    public let sessionId: String
    public let pid: pid_t?
    public let timestamp: Date?
    public let body: String?
    public let activityId: String?
    public let lifecycleId: String?
    public let lifecycleOrder: UInt64?

    public init(
        version: Int,
        event: ActivityEvent,
        agent: AgentKind,
        sessionId: String,
        pid: pid_t?,
        timestamp: Date?,
        body: String?,
        activityId: String? = nil,
        lifecycleId: String? = nil,
        lifecycleOrder: UInt64? = nil
    ) {
        self.version = version
        self.event = event
        self.agent = agent
        self.sessionId = sessionId
        self.pid = pid
        self.timestamp = timestamp
        self.body = body
        self.activityId = activityId
        self.lifecycleId = lifecycleId
        self.lifecycleOrder = lifecycleOrder
    }
}

extension AgentHookEvent {
    public static func decode(from data: Data) throws -> AgentHookEvent {
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
        let activityId = (json["activity_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let lifecycleId = (json["lifecycle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let lifecycleOrder = (json["lifecycle_order"] as? String).flatMap(UInt64.init)
        return AgentHookEvent(
            version: v, event: event, agent: agent,
            sessionId: sessionId, pid: pid, timestamp: ts, body: body,
            activityId: activityId, lifecycleId: lifecycleId, lifecycleOrder: lifecycleOrder
        )
    }
}

public enum AgentHookEventError: Error, Equatable, Sendable {
    case malformed(String)
    case unknownEvent(String)
}
