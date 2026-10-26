import Foundation
import AlasCode

/// Canonical upstream messages and projection effects, without transport,
/// persistence, v1 replay heuristics, or foreground lifecycle side effects.
public struct ACPV2MessageTranscript: Sendable {
    public struct Context: Equatable, Sendable {
        public let sessionID: String
        public let connectionID: UUID

        public init(sessionID: String, connectionID: UUID) {
            self.sessionID = sessionID
            self.connectionID = connectionID
        }
    }

    public struct Key: Hashable, Sendable {
        public let kind: ACPV2SessionUpdateEnvelope.MessageKind
        public let messageID: String

        public init(kind: ACPV2SessionUpdateEnvelope.MessageKind, messageID: String) {
            self.kind = kind
            self.messageID = messageID
        }
    }

    public struct Message: Equatable, Sendable {
        public let key: Key
        public let content: [LSPJSONValue]
        public let metadata: [String: LSPJSONValue]
        public let localRowID: UUID?
    }

    public enum Effect: Equatable, Sendable {
        /// Reuse this local row's UUID and local-only metadata at the entity's
        /// observed position, removing only its optimistic placeholder.
        case reconcile(key: Key, localRowID: UUID)
        case messageChanged(Message)
    }

    public enum Correlation: Equatable, Sendable {
        case registered, bound, unchanged, unmatched, conflict, staleContext
        case reconciled(key: Key, localRowID: UUID)
    }

    public struct Reduction: Equatable, Sendable {
        public enum Disposition: Equatable, Sendable { case applied, unhandled, staleContext }
        public let event: ACPV2SessionUpdateEnvelope
        public let disposition: Disposition
        public let effects: [Effect]
    }

    public let context: Context
    public private(set) var messages: [Message] = []
    private var indices: [Key: Int] = [:]
    private struct Registration {
        let localRowID: UUID
        var messageID: String?
    }
    private var registrations: [Int: Registration] = [:]
    private var requestByRow: [UUID: Int] = [:]
    private var requestByMessage: [String: Int] = [:]

    public init(context: Context) { self.context = context }

    public func message(for key: Key) -> Message? { indices[key].map { messages[$0] } }

    @discardableResult
    public mutating func register(requestID: Int, localRowID: UUID, context: Context) -> Correlation {
        guard context == self.context else { return .staleContext }
        if let existing = registrations[requestID] {
            return existing.localRowID == localRowID ? .unchanged : .conflict
        }
        guard requestByRow[localRowID] == nil else { return .conflict }
        registrations[requestID] = Registration(localRowID: localRowID)
        requestByRow[localRowID] = requestID
        return .registered
    }

    /// Correlates insertion only. It never creates content, dispatches work,
    /// or changes foreground state. The owner retains uncertain submissions.
    @discardableResult
    public mutating func accept(requestID: Int, response: ACPV2PromptAccepted, context: Context) -> Correlation {
        guard context == self.context else { return .staleContext }
        guard var registration = registrations[requestID] else { return .unmatched }
        if let existing = registration.messageID {
            return existing == response.messageID ? .unchanged : .conflict
        }
        guard requestByMessage[response.messageID] == nil else { return .conflict }
        registration.messageID = response.messageID
        registrations[requestID] = registration
        requestByMessage[response.messageID] = requestID
        let key = Key(kind: .user, messageID: response.messageID)
        guard let index = indices[key] else { return .bound }
        let old = messages[index]
        messages[index] = Message(key: key, content: old.content, metadata: old.metadata,
            localRowID: registration.localRowID)
        return .reconciled(key: key, localRowID: registration.localRowID)
    }

    @discardableResult
    public mutating func apply(_ event: ACPV2SessionUpdateEnvelope, context: Context) -> Reduction {
        guard context == self.context, event.sessionID == context.sessionID else {
            return Reduction(event: event, disposition: .staleContext, effects: [])
        }
        guard let mutation = event.message else {
            return Reduction(event: event, disposition: .unhandled, effects: [])
        }
        let key = Key(kind: mutation.kind, messageID: mutation.messageID)
        let old = message(for: key)
        var content = old?.content ?? []
        switch mutation.content {
        case .unchanged: break
        case .replace(let blocks): content = blocks
        case .append(let block): content.append(block)
        }
        let metadata = mutation.metadata.applying(to: old?.metadata ?? [:])
        let localRowID = key.kind == .user
            ? requestByMessage[key.messageID].flatMap { registrations[$0]?.localRowID } : nil
        let message = Message(key: key, content: content, metadata: metadata, localRowID: localRowID)
        guard old != message else {
            return Reduction(event: event, disposition: .applied, effects: [])
        }
        if let index = indices[key] { messages[index] = message }
        else {
            indices[key] = messages.count
            messages.append(message)
        }
        var effects: [Effect] = []
        if old?.localRowID == nil, let localRowID {
            effects.append(.reconcile(key: key, localRowID: localRowID))
        }
        effects.append(.messageChanged(message))
        return Reduction(event: event, disposition: .applied, effects: effects)
    }
}
