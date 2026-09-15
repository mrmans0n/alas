import AppKit
import Foundation

/// Handles context-menu navigation requests that return durable reference
/// results. The binding is synchronized before every request so unsaved buffer
/// text is authoritative and responses from replaced documents are discarded.
@MainActor
final class NavigationFeature {
    enum Action {
        case references
    }
    typealias SynchronizeRequest = (_ range: NSRange) async -> (LSPClient, EditorRequestContext)?

    private let synchronizeRequest: SynchronizeRequest
    private let isContextCurrent: (EditorRequestContext) -> Bool
    private let isQueryCurrent: (EditorRequestContext) -> Bool
    private let currentStore: () -> EditorNavigationStore
    private var requestID: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private weak var inFlightReferenceStore: EditorNavigationStore?

    init(
        store: @escaping () -> EditorNavigationStore,
        synchronizeRequest: @escaping SynchronizeRequest,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool,
        isQueryCurrent: ((EditorRequestContext) -> Bool)? = nil
    ) {
        currentStore = store
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent
        self.isQueryCurrent = isQueryCurrent ?? isContextCurrent
    }

    func perform(_ action: Action, range: NSRange) {
        cancelPendingRequest()
        requestID += 1
        let currentRequestID = requestID
        let requestStore = currentStore()
        requestStore.beginLoading()
        requestStore.cancelRequestHandler = { [weak self] in self?.cancelPendingRequest() }
        inFlightReferenceStore = requestStore
        inFlight = Task { [weak self] in
            guard let self else { return }
            guard let (client, context) = await synchronizeRequest(range), !Task.isCancelled else {
                if requestID == currentRequestID { requestStore.showUnavailable("Language server unavailable") }
                return
            }
            requestStore.retainReferenceQuery(client: client, context: context, isCurrent: isQueryCurrent)
            do {
                let locations = try await client.references(
                    uri: context.document.uri,
                    position: context.range.start,
                    includeDeclaration: true
                )
                guard !Task.isCancelled else {
                    await MainActor.run { [weak self] in self?.finishLoading(requestID: currentRequestID, store: requestStore) }
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentRequestID else { return }
                    guard self.isContextCurrent(context) else {
                        self.finishLoading(requestID: currentRequestID, store: requestStore)
                        return
                    }
                    let targets = locations.map {
                        EditorNavigationTarget(
                            document: EditorDocumentID(
                                host: context.document.host,
                                worktreeID: context.document.worktreeID,
                                uri: $0.uri
                            ),
                            position: $0.range.start
                        )
                    }
                    requestStore.replaceResults(targets)
                    self.inFlightReferenceStore = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.requestID == currentRequestID else { return }
                    guard self.isContextCurrent(context) else {
                        self.finishLoading(requestID: currentRequestID, store: requestStore)
                        return
                    }
                    requestStore.fail(error)
                    self.inFlightReferenceStore = nil
                }
            }
        }
    }

    func cancelPendingRequest() {
        requestID += 1
        inFlight?.cancel()
        inFlight = nil
        inFlightReferenceStore?.cancelLoading()
        inFlightReferenceStore = nil
    }

    private func finishLoading(requestID: UInt64, store: EditorNavigationStore) {
        guard self.requestID == requestID else { return }
        store.cancelLoading()
        inFlightReferenceStore = nil
    }
}
