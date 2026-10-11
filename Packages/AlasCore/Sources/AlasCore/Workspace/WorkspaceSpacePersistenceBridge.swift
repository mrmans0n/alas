import Foundation

public actor WorkspaceSpacePersistenceBridge {
    private let workspaceStore: WorkspaceStore

    public init(workspaceStore: WorkspaceStore = WorkspaceStore()) {
        self.workspaceStore = workspaceStore
    }

    public func load() async -> WorkspaceStoreLoadResult {
        await workspaceStore.load()
    }

    public func reconcileOnLoad(spacesFile: SpacesFile) async throws -> SpacesFile? {
        try await workspaceStore.reconcileSpaceLayouts(with: spacesFile)
    }

    /// Records a freshly-written typed layout only after the legacy Spaces
    /// projection has been persisted successfully.
    public func checkpointAfterSpacesWrite(_ spacesFile: SpacesFile) async throws {
        try await workspaceStore.checkpointSpaceLayouts(afterWriting: spacesFile)
    }

    public func reconcileCheckout(
        id: UUID,
        observer: any WorkspaceCheckoutObserving = WorkspaceCheckoutObserver()
    ) async throws -> WorkspaceCheckoutReconciliation {
        try await WorkspaceCheckoutReconciler(store: workspaceStore, observer: observer).reconcile(checkoutID: id)
    }
}
