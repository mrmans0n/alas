import Foundation

actor WorkspaceSpacePersistenceBridge {
    private let workspaceStore: WorkspaceStore

    init(workspaceStore: WorkspaceStore = WorkspaceStore()) {
        self.workspaceStore = workspaceStore
    }

    func load() async -> WorkspaceStoreLoadResult {
        await workspaceStore.load()
    }

    func reconcileOnLoad(spacesFile: SpacesFile) async throws -> SpacesFile? {
        try await workspaceStore.reconcileSpaceLayouts(with: spacesFile)
    }

    /// Records a freshly-written typed layout only after the legacy Spaces
    /// projection has been persisted successfully.
    func checkpointAfterSpacesWrite(_ spacesFile: SpacesFile) async throws {
        try await workspaceStore.checkpointSpaceLayouts(afterWriting: spacesFile)
    }
}
