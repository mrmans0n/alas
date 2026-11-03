import Foundation
import AlasACP
import AlasPlatform

/// Post-setup composition only. Protocol selection, application queues and
/// process closure remain with the connection/runner integration.
@MainActor
public final class ACPV2AttachmentRuntime {
    public enum Failure: Error, Equatable, Sendable {
        case invalidAttachment, invalidHandle, notReady, invalidated, ownershipLost
        case updates(ACPV2SessionUpdateOwner.Failure)
        case inbound(ACPV2InboundReceiptOwner.Failure)
    }
    public enum Status: Equatable, Sendable {
        case idle, restoring, ready, observationLost, stopped
        case blocked(Failure)
    }
    public struct Request: Sendable {
        public let record: ACPV2InboundLedgerRecord
        fileprivate let epoch: UUID
        fileprivate let delivery: ACPV2InboundDelivery
    }
    public struct Journals: Sendable {
        public let updates: any ACPV2UpdateJournalPersisting
        public let inbound: any ACPV2InboundLedgerPersisting
        public let submissions: any ACPV2SubmissionPersisting
        public let responses: any ACPV2ResponseLedgerPersisting
        public init(persistence: ACPSessionPersistence, updates: (any ACPV2UpdateJournalPersisting)? = nil,
            inbound: (any ACPV2InboundLedgerPersisting)? = nil, submissions: (any ACPV2SubmissionPersisting)? = nil,
            responses: (any ACPV2ResponseLedgerPersisting)? = nil) {
            self.updates = updates ?? persistence
            self.inbound = inbound ?? persistence
            self.submissions = submissions ?? persistence
            self.responses = responses ?? persistence
        }
    }
    public struct Attachment: Sendable {
        fileprivate enum Client: Sendable { case stdio(ACPStdioClient), broker(ACPBrokerClient) }
        fileprivate let client: Client
        fileprivate let updates: ACPV2SessionUpdateOwner.Attachment
        fileprivate let inbound: ACPV2InboundReceiptOwner.Attachment
        fileprivate let response: ACPV2ResponseAttachment
        fileprivate let localSessionId: String?
        public var connectionID: UUID { inbound.connectionID }

        @MainActor
        public init(stdioClient: ACPStdioClient) throws {
            inbound = try .init(stdioClient: stdioClient)
            response = try .init(stdioClient: stdioClient)
            updates = .init(freshStdioConnectionID: stdioClient.updateConnectionID)
            client = .stdio(stdioClient)
            localSessionId = nil
        }
        @MainActor
        public init(brokerClient: ACPBrokerClient, opened: ACPBrokerOpenResult) throws {
            inbound = try .init(brokerClient: brokerClient, opened: opened)
            response = try .init(brokerClient: brokerClient, opened: opened)
            updates = try .init(brokerConnectionID: inbound.connectionID, opened: opened)
            client = .broker(brokerClient)
            localSessionId = opened.snapshot.metadata.alasSessionId
        }
        fileprivate var sender: any ACPV2PromptSending {
            switch client { case .stdio(let client): client
            case .broker(let client): client }
        }
        fileprivate var updateInput: AsyncStream<ACPV2SessionUpdateDelivery> {
            switch client { case .stdio(let client): client.incomingV2Updates
            case .broker(let client): client.incomingV2Updates }
        }
    }

    public private(set) var status: Status = .idle
    /// Latest-only status. Request offers use the reliable synchronous callback.
    public let observations: AsyncStream<Status>
    public var state: ACPV2SessionState { updateOwner.state }
    public var inboundStream: ACPV2InboundLedgerStream? { inboundOwner.stream }
    private let continuation: AsyncStream<Status>.Continuation
    private let epoch = UUID()
    private let sessionId: String
    private let upstreamSessionId: String
    private let attachment: Attachment
    private let fence: ACPSessionLeaseFence
    private let journals: Journals
    private let isCurrent: @MainActor () -> Bool
    private let onRequest: @MainActor (Request) -> Void
    private let onCanonicalChange: (@MainActor (ACPV2SessionUpdateOwner.CanonicalPublication) throws -> Void)?
    private var active = true
    private var started = false
    private var ownersStarted = false
    private var offered: Set<Int64> = []
    private var diagnostics: Set<UUID> = []
    private var readers: [Task<Void, Never>] = []
    private var monitors: [Task<Void, Never>] = []
    private var input: AsyncStream<ACPV2InboundDelivery>.Continuation?
    private var responseOwner: ACPV2ResponseOwner?

    private lazy var updateOwner = ACPV2SessionUpdateOwner(sessionId: sessionId, upstreamSessionId: upstreamSessionId,
        attachment: attachment.updates, fence: fence, journal: journals.updates,
        submissions: .init(sender: attachment.sender, journal: journals.submissions),
        isCurrent: { [weak self] in self?.current() == true },
        onCanonicalChange: { [weak self] publication in try self?.canonicalChanged(publication) })
    private lazy var inboundOwner = ACPV2InboundReceiptOwner(sessionId: sessionId, upstreamSessionId: upstreamSessionId,
        attachment: attachment.inbound, fence: fence, journal: journals.inbound,
        isCurrent: { [weak self] in self?.current() == true },
        onStreamRegistered: { [weak self] stream in try self?.registered(stream) },
        onRetained: { [weak self] delivery, receipt in try self?.retained(delivery, receipt: receipt) })

    public init(sessionId: String, upstreamSessionId: String, attachment: Attachment, fence: ACPSessionLeaseFence,
        journals: Journals, isCurrent: @escaping @MainActor () -> Bool, onRequest: @escaping @MainActor (Request) -> Void,
        onCanonicalChange: (@MainActor (ACPV2SessionUpdateOwner.CanonicalPublication) throws -> Void)? = nil) throws {
        guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, sessionId.utf8.elementsEqual(fence.sessionId.utf8),
              attachment.localSessionId.map({ $0.utf8.elementsEqual(sessionId.utf8) }) ?? true else { throw Failure.invalidAttachment }
        self.sessionId = sessionId
        self.upstreamSessionId = upstreamSessionId
        self.attachment = attachment
        self.fence = fence
        self.journals = journals
        self.isCurrent = isCurrent
        self.onRequest = onRequest
        self.onCanonicalChange = onCanonicalChange
        let stream = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = stream.stream
        continuation = stream.continuation
    }

    deinit {
        for task in readers { task.cancel() }
        for task in monitors { task.cancel() }
        input?.finish()
    }

    public func establishFreshSessionDefault() throws {
        guard !started, current() else { throw Failure.invalidated }
        try updateOwner.establishFreshSessionDefault()
    }

    @discardableResult
    public func start() -> Bool {
        guard !started, current() else { return false }
        started = true
        setStatus(.restoring)
        guard updateOwner.start(attachment.updateInput) else { finish(.blocked(.invalidAttachment))
        return false }
        switch attachment.client {
        case .broker(let client):
            guard inboundOwner.start(client.incomingRawFrames) else { finish(.blocked(.invalidAttachment))
            return false }
        case .stdio(let client):
            let merged = AsyncStream<ACPV2InboundDelivery>.makeStream()
            input = merged.continuation
            guard inboundOwner.start(merged.stream) else { finish(.blocked(.invalidAttachment))
            return false }
            readers.append(Task { [weak self] in
                for await delivery in client.incomingV2Inbound {
                    guard let self else { return }
                    guard self.current() else { self.finish(.blocked(.ownershipLost))
                    return }
                    merged.continuation.yield(delivery)
                }
                self?.sourceEnded()
            })
            readers.append(Task { [weak self] in
                for await diagnostic in client.incomingRawRPCDiagnostics {
                    guard let self else { return }
                    guard self.current() else { self.finish(.blocked(.ownershipLost))
                    return }
                    do {
                        let delivery = try ACPV2InboundDelivery(stdioDiagnostic: diagnostic)
                        self.diagnostics.insert(delivery.receiptID)
                        merged.continuation.yield(delivery)
                    } catch { self.finish(.blocked(.invalidAttachment))
                    return }
                }
                self?.sourceEnded()
            })
        }
        ownersStarted = true
        let updates = updateOwner.observations
        let inbound = inboundOwner.observations
        monitors.append(Task { [weak self] in
            for await _ in updates { self?.synchronize() }
            self?.synchronize()
        })
        monitors.append(Task { [weak self] in
            for await _ in inbound { self?.synchronize() }
            self?.synchronize()
        })
        synchronize()
        return true
    }

    public func stop() { finish(.stopped) }

    public func submit(id: UUID, localRowID: UUID, params: ACPSessionPromptParams,
        operationKey: ACPBrokerOperationKey? = nil) async throws -> ACPV2SubmissionRecord {
        try requireReady()
        let result = try await updateOwner.submit(id: id, localRowID: localRowID, params: params, operationKey: operationKey)
        try requireReady()
        return result
    }

    public func respond(to request: Request, intentID: UUID, attemptID: UUID, operationKey: ACPV2ReplyOperationKey,
        frame: Data) async throws -> ACPV2ResponseOwner.Receipt {
        try requireReady()
        guard request.epoch == epoch, request.record.streamID == inboundStream?.id,
              offered.contains(request.record.ordinal), let responseOwner else { throw Failure.invalidHandle }
        let result = try await responseOwner.respond(request: request.record, delivery: request.delivery,
            intentID: intentID, attemptID: attemptID, operationKey: operationKey, frame: frame)
        try requireReady()
        return result
    }

    private func canonicalChanged(_ publication: ACPV2SessionUpdateOwner.CanonicalPublication) throws {
        // Terminal display withdrawal must reach the installation even after
        // runtime authority is gone. It never authorizes a command or ACK.
        if case .observationLost = publication.change {
            try onCanonicalChange?(publication)
            return
        }
        guard current() else { throw Failure.invalidated }
        do { try onCanonicalChange?(publication) }
        catch {
            finish(.blocked(.updates(.projection(message: String(describing: error)))))
            throw error
        }
        guard current() else { finish(.blocked(.ownershipLost))
        throw Failure.invalidated }
    }

    private func current() -> Bool {
        guard active, isCurrent(), active else { return false }
        // A child may fail before its monitor task runs. Every worker and
        // consumption boundary must observe that loss synchronously.
        if let terminal = terminalChildStatus() { finish(terminal)
        return false }
        return true
    }

    private func terminalChildStatus() -> Status? {
        // Do not instantiate lazy children recursively during construction.
        guard ownersStarted else { return nil }
        switch updateOwner.status {
        case .blocked(let failure): return .blocked(.updates(failure))
        case .observationLost: return .observationLost
        case .stopped: return .blocked(.ownershipLost)
        default: break
        }
        switch inboundOwner.status {
        case .blocked(let failure): return .blocked(.inbound(failure))
        case .observationLost: return .observationLost
        case .stopped: return .blocked(.ownershipLost)
        default: return nil
        }
    }
    private func requireReady() throws {
        try Task.checkCancellation()
        guard current() else { if active { finish(.blocked(.ownershipLost)) }
        throw Failure.invalidated }
        synchronize()
        guard active else { throw Failure.invalidated }
        guard status == .ready else { throw Failure.notReady }
    }
    private func registered(_ stream: ACPV2InboundLedgerStream) throws {
        guard current(), responseOwner == nil else { throw Failure.invalidated }
        responseOwner = try .init(stream: stream, fence: fence, attachment: attachment.response,
            journal: journals.responses, isCurrent: { [weak self] in self?.current() == true })
    }
    private func retained(_ delivery: ACPV2InboundDelivery, receipt: ACPV2InboundLedgerReceipt) throws {
        guard current(), receipt.record.streamID == inboundStream?.id else { throw Failure.invalidated }
        if diagnostics.remove(delivery.receiptID) != nil { return }
        guard let header = try? delivery.decodeHeader(), header.id != nil,
              offered.insert(receipt.record.ordinal).inserted else { return }
        onRequest(.init(record: receipt.record, epoch: epoch, delivery: delivery))
    }
    private func synchronize() {
        guard active, started else { return }
        guard current() else { finish(.blocked(.ownershipLost))
        return }
        setStatus(updateOwner.status == .live && inboundOwner.status == .receiving && responseOwner != nil ? .ready : .restoring)
    }
    private func sourceEnded() { if active { finish(.observationLost) } }
    private func setStatus(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        continuation.yield(status)
    }
    private func finish(_ status: Status) {
        guard active else { return }
        active = false
        setStatus(status)
        responseOwner?.stop()
        inboundOwner.stop()
        updateOwner.stop()
        for task in readers { task.cancel() }
        for task in monitors { task.cancel() }
        input?.finish()
        continuation.finish()
    }
}
