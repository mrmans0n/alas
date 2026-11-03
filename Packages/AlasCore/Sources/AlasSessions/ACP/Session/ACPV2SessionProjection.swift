import Foundation
import AlasACP
import AlasModel
import AlasCode

/// Opt-in display projection. It grants no request, queue or process authority.
@MainActor
public final class ACPV2SessionProjection {
    public enum Failure: Error, Equatable, Sendable {
        case invalidDestination, invalidContext, revisionGap, conflictingIdentity, invalidated
    }
    public struct State: Sendable {
        public let epoch: UUID
        public var canonical: ACPV2SessionState
        public var foreground: ACPForegroundState
        public var isObserving: Bool
        public var submissions: [Int: ACPSessionLifecycle.Submission] = [:]
    }
    public struct Notification: Sendable {
        public let publication: ACPV2SessionUpdateOwner.CanonicalPublication
        public let liveCompletions: [ACPSessionLifecycle.ForegroundCompletion]
    }
    private let session: ACPSession
    private let epoch = UUID()
    private let context: ACPV2SessionState.Context
    private let isCurrent: @MainActor () -> Bool
    private let onChange: (@MainActor (Notification) -> Void)?
    private var active = true
    private var applying = false
    private var revision: UInt64 = 0
    private var rowKeys: [ACPV2SessionState.Key] = []
    private var rowIDs: [ACPV2SessionState.Key: UUID] = [:]
    private var optimistic: [UUID: ACPMessage] = [:]
    private var completions: Set<Int> = []
    private var submissions: [Int: ACPSessionLifecycle.Submission] = [:]

    public init(session: ACPSession, upstreamSessionId: String, connectionID: UUID,
        optimisticRowIDs: Set<UUID> = [], isCurrent: @escaping @MainActor () -> Bool,
        onChange: (@MainActor (Notification) -> Void)? = nil) throws {
        self.session = session
        context = .init(sessionID: upstreamSessionId, connectionID: connectionID)
        self.isCurrent = isCurrent
        self.onChange = onChange
        guard !upstreamSessionId.isEmpty else { throw Failure.invalidContext }
        for row in session.transcript.messages {
            guard case .user(let id, let messageID, _, _, _, _) = row,
                  messageID == nil, optimisticRowIDs.contains(id), optimistic[id] == nil else { throw Failure.invalidDestination }
            optimistic[id] = row
        }
        guard Set(optimistic.keys) == optimisticRowIDs else { throw Failure.invalidDestination }
        try session.reserveV2Projection(epoch: epoch)
        let canonical = ACPV2SessionState(context: context)
        guard session.storeV2Projection(.init(epoch: epoch, canonical: canonical, foreground: .unknown, isObserving: true), authorize: { self.current() }) else {
            stop()
            throw Failure.invalidated
        }
    }

    /// Register a newly composed row before submitting its UUID to the
    /// runtime. Identity is explicit; equal text never establishes correlation.
    public func registerOptimisticRow(_ row: ACPMessage) throws {
        do {
            try requireCurrent()
            guard !applying, case .user(let id, nil, _, _, _, _) = row,
                  optimistic[id] == nil, !rowIDs.values.contains(id),
                  !session.transcript.messages.contains(where: { existing in
                      if case .user(let other, _, _, _, _, _) = existing { return other == id }
                      return false
                  }) else { throw Failure.conflictingIdentity }
            applying = true
            defer { applying = false }
            guard session.transcript.projectMessage(row, at: session.transcript.messages.count, replacing: false,
                removingIndices: [], authorize: { self.current() }) else { throw Failure.invalidated }
            optimistic[id] = row
            try requireCurrent()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        guard active else { return }
        active = false
        session.releaseV2Projection(epoch: epoch)
    }

    private func current() -> Bool {
        active && session.v2ProjectionEpoch == epoch && isCurrent() && active && session.v2ProjectionEpoch == epoch
    }
    private func requireCurrent() throws { guard current() else { throw Failure.invalidated } }

    public func apply(_ publication: ACPV2SessionUpdateOwner.CanonicalPublication) throws {
        do {
            try requireCurrent()
            guard !applying else { throw Failure.conflictingIdentity }
            applying = true
            defer { applying = false }
            guard publication.context == context, publication.state.context == context else { throw Failure.invalidContext }
            guard publication.revision == revision + 1 else { throw Failure.revisionGap }
            let effects: [ACPV2SessionState.Effect]
            var observing = true
            var live = false
            switch publication.change {
            case .update(let application): effects = application.effects
            live = application.source == .live
            case .submission(let application, let source):
                if case .registration = source, optimistic[application.record.registration.localRowID] == nil {
                    throw Failure.conflictingIdentity
                }
                effects = application.effects
                let id = application.record.registration.sequence
                submissions[id] = publication.state.lifecycle.submission(id)
            case .setupDefault(let result): effects = result.effects
            case .observationLost(let loss): effects = loss
            observing = false
            }
            var changed = Set<ACPV2SessionState.Key>()
            for effect in effects {
                switch effect {
                case .message(.messageChanged(let value)): changed.insert(.message(value.key))
                case .message(.reconcile(let key, _)): changed.insert(.message(key))
                case .activity(.toolCallChanged(let value)): changed.insert(.toolCall(value.toolCallID))
                case .activity(.planChanged(let value)): changed.insert(.plan(value.planID))
                default: break
                }
            }
            for key in publication.state.order where changed.contains(key) {
                try requireCurrent()
                try project(key, state: publication.state)
            }
            try requireCurrent()
            for id in submissions.keys {
                let value = publication.state.lifecycle.submission(id)
                submissions[id] = !observing && value == .pending ? .uncertain : value
            }
            var projected = State(epoch: epoch, canonical: publication.state,
                foreground: observing ? publication.state.lifecycle.foreground : .unknown, isObserving: observing)
            projected.submissions = submissions
            guard session.storeV2Projection(projected, authorize: { self.current() }) else { throw Failure.invalidated }
            try requireCurrent()
            revision = publication.revision
            var ended: [ACPSessionLifecycle.ForegroundCompletion] = []
            if live {
                for effect in effects {
                    if case .lifecycle(.foregroundEnded(let end)) = effect, completions.insert(end.generation).inserted { ended.append(end) }
                }
            }
            onChange?(.init(publication: publication, liveCompletions: ended))
            try requireCurrent()
        } catch {
            stop()
            throw error
        }
    }

    private func project(_ key: ACPV2SessionState.Key, state: ACPV2SessionState) throws {
        let existingIndex = rowKeys.firstIndex(of: key)
        let index = existingIndex ?? state.order.prefix(while: { $0 != key }).filter { rowKeys.contains($0) }.count
        var id = rowIDs[key] ?? UUID()
        var remove: [Int] = []
        let row: ACPMessage
        switch key {
        case .message(let messageKey):
            guard let value = state.transcript.message(for: messageKey) else { throw Failure.conflictingIdentity }
            var local: ACPMessage?
            if let localID = value.localRowID {
                guard let original = optimistic[localID], messageKey.kind == .user else { throw Failure.conflictingIdentity }
                local = original
                id = localID
                remove = session.transcript.messages.indices.filter { position in
                    if case .user(let candidate, _, _, _, _, _) = session.transcript.messages[position] {
                        return candidate == localID && position != existingIndex
                    }
                    return false
                }
            }
            let text = Self.text(value.content)
            switch messageKey.kind {
            case .user:
                var attachments = Self.attachments(value.content)
                var source: ACPDelegatedPromptSource?
                var pasted: [ACPPastedTextSpan] = []
                if case .user(_, _, _, let localAttachments, let delegated, let localPasted)? = local {
                    attachments = localAttachments + attachments.filter { !localAttachments.contains($0) }
                    source = delegated
                    pasted = localPasted
                }
                row = .user(id: id, messageId: messageKey.messageID, text: text, attachments: attachments, delegatedSource: source, pastedSpans: pasted)
            case .agent: row = .agent(id: id, messageId: messageKey.messageID, StreamingText(text))
            case .thought: row = .thought(id: id, messageId: messageKey.messageID, StreamingText(text))
            }
        case .toolCall(let toolID):
            guard let value = state.activity.toolCall(id: toolID) else { throw Failure.conflictingIdentity }
            let content = value.content.map { item -> LSPJSONValue in
                if case .object(let fields) = item.rawValue, let content = fields["content"] { return content }
                return item.rawValue
            }
            row = .toolCall(.init(toolCallId: toolID, title: value.title ?? value.name ?? toolID, kind: value.kind,
                status: value.status ?? "unknown", content: Self.text(content),
                locations: value.locations.compactMap { if case .object(let fields) = $0, case .string(let path)? = fields["path"] { return path }
                return nil },
                terminalIds: value.content.compactMap(\.terminalID), name: value.name))
        case .plan(let planID):
            guard let value = state.activity.plan(id: planID) else { throw Failure.conflictingIdentity }
            let items = (value.entries ?? []).compactMap { entry -> ACPMessage.PlanItem? in
                guard case .object(let fields) = entry, case .string(let content)? = fields["content"],
                      case .string(let status)? = fields["status"] else { return nil }
                return .init(content: content, status: status)
            }
            row = .plan(id: id, items)
        case .terminal: return
        }
        guard session.transcript.projectMessage(row, at: index, replacing: existingIndex != nil,
            removingIndices: remove, authorize: { self.current() }) else { throw Failure.invalidated }
        rowIDs[key] = id
        if existingIndex == nil { rowKeys.insert(key, at: index) }
    }

    private static func text(_ content: [LSPJSONValue]) -> String {
        content.compactMap { block -> String? in
            guard case .object(let fields) = block, case .string("text")? = fields["type"],
                  case .string(let text)? = fields["text"] else { return nil }
            return text
        }.joined()
    }

    private static func attachments(_ content: [LSPJSONValue]) -> [ACPMessage.Attachment] {
        content.compactMap { block in
            guard case .object(let fields) = block, case .string(let type)? = fields["type"] else { return nil }
            if type == "resource_link", case .string(let uri)? = fields["uri"] {
                let name: String? = if case .string(let value)? = fields["name"] { value } else { nil }
                return .init(uri: uri, name: name)
            }
            if type == "image", case .string(let data)? = fields["data"], case .string(let mime)? = fields["mimeType"] {
                return .init(uri: "data:\(mime);base64,\(data)", name: nil, mimeType: mime)
            }
            return nil
        }
    }
}
