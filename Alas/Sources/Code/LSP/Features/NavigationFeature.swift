import AppKit
import Foundation

/// Handles context-menu navigation requests that return durable reference
/// results. The binding is synchronized before every request so unsaved buffer
/// text is authoritative and responses from replaced documents are discarded.
@MainActor
final class NavigationFeature {
    enum Action {
        case typeDefinition
        case implementation
        case references
    }
    typealias SynchronizeRequest = (_ range: NSRange) async -> (LSPClient, EditorRequestContext)?

    private let synchronizeRequest: SynchronizeRequest
    private let isContextCurrent: (EditorRequestContext) -> Bool
    private let store: EditorNavigationStore
    private let openTarget: (EditorNavigationTarget) -> Void
    private var requestID: UInt64 = 0
    private var inFlight: Task<Void, Never>?

    init(
        store: EditorNavigationStore,
        synchronizeRequest: @escaping SynchronizeRequest,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool,
        openTarget: @escaping (EditorNavigationTarget) -> Void
    ) {
        self.store = store
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent
        self.openTarget = openTarget
    }

    func perform(_ action: Action, range: NSRange) {
        requestID += 1
        let currentRequestID = requestID
        inFlight?.cancel()
        if action == .references { store.beginLoading() }
        inFlight = Task { [weak self] in
            guard let self,
                  let (client, context) = await synchronizeRequest(range),
                  !Task.isCancelled
            else { return }
            do {
                let locations: [LSPLocation]
                switch action {
                case .typeDefinition:
                    locations = try await client.typeDefinition(uri: context.document.uri, position: context.range.start)
                case .implementation:
                    locations = try await client.implementation(uri: context.document.uri, position: context.range.start)
                case .references:
                    locations = try await client.references(
                        uri: context.document.uri,
                        position: context.range.start,
                        includeDeclaration: true
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.requestID == currentRequestID,
                          self.isContextCurrent(context)
                    else { return }
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
                    if action == .references || targets.count != 1 {
                        self.store.replaceResults(targets)
                    } else if let target = targets.first {
                        self.openTarget(target)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.requestID == currentRequestID,
                          self.isContextCurrent(context)
                    else { return }
                    self.store.fail(error)
                }
            }
        }
    }
}
