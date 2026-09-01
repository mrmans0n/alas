import Foundation

struct WorkspaceRecoveryState: Codable, Equatable, Sendable {
    var originalFilePath: String
    var quarantinedFilePath: String?
    var message: String

    var originalFileURL: URL { URL(fileURLWithPath: originalFilePath) }
    var quarantinedFileURL: URL? { quarantinedFilePath.map(URL.init(fileURLWithPath:)) }
}

enum WorkspaceStoreLoadResult: Equatable, Sendable {
    case missing
    case loaded(WorkspaceStateFile)
    case unreadable(WorkspaceRecoveryState)
}

enum WorkspaceStoreError: Error, Equatable, Sendable {
    case recoveryRequired
}

actor WorkspaceStore {
    private let store: PersistenceStore
    private let url: URL

    init(store: PersistenceStore = PersistenceStore(), url: URL = Paths.workspacesFile) {
        self.store = store
        self.url = url
    }

    func load() -> WorkspaceStoreLoadResult {
        if let recovery = readRecoveryState() {
            return .unreadable(recovery)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let recovery = recoveryFromQuarantineArtifact() {
                return .unreadable(recovery)
            }
            return .missing
        }
        do {
            return .loaded(try decodeState())
        } catch {
            return .unreadable(quarantine(error: error))
        }
    }

    func checkout(id: UUID) -> WorkspaceCheckout? {
        guard case .loaded(let state) = load() else { return nil }
        return state.checkouts.first(where: { $0.id == id })
    }

    func checkpoint(_ state: WorkspaceStateFile) throws {
        if case .unreadable = load() {
            throw WorkspaceStoreError.recoveryRequired
        }
        try checkpointLoaded(state)
    }

    /// Performs a whole-state update under the store actor. Checkout member
    /// workers use this rather than separate load/checkpoint calls so one
    /// member cannot overwrite another member's checkpoint.
    func mutate<Value: Sendable>(
        _ update: (inout WorkspaceStateFile) throws -> Value
    ) throws -> Value {
        var state: WorkspaceStateFile
        switch load() {
        case .missing:
            state = WorkspaceStateFile()
        case .loaded(let loaded):
            state = loaded
        case .unreadable:
            throw WorkspaceStoreError.recoveryRequired
        }
        let value = try update(&state)
        try checkpointLoaded(state)
        return value
    }

    /// Reconciles legacy Space membership and checkpoints the resulting typed
    /// layout in one actor-isolated read-modify-write operation.
    func reconcileSpaceLayouts(with spacesFile: SpacesFile) throws -> SpacesFile? {
        switch load() {
        case .missing:
            return nil
        case .unreadable:
            throw WorkspaceStoreError.recoveryRequired
        case .loaded(var state):
            let originalState = state
            let reconciled = state.reconcileSpaceLayouts(with: spacesFile)
            guard state != originalState else {
                return reconciled == spacesFile ? nil : reconciled
            }
            try checkpointLoaded(state)
            return reconciled == spacesFile ? nil : reconciled
        }
    }

    /// Records a typed Space layout after its legacy projection has been
    /// written. The entire read-modify-write is serialized by this actor.
    func checkpointSpaceLayouts(afterWriting spacesFile: SpacesFile) throws {
        switch load() {
        case .missing:
            return
        case .unreadable:
            throw WorkspaceStoreError.recoveryRequired
        case .loaded(var state):
            let originalState = state
            state.checkpointSpaceLayouts(from: spacesFile)
            guard state != originalState else { return }
            try checkpointLoaded(state)
        }
    }

    func discardUnreadableState() throws {
        let fileManager = FileManager.default
        let recovery = readRecoveryState()
        if let quarantinedFileURL = recovery?.quarantinedFileURL,
           fileManager.fileExists(atPath: quarantinedFileURL.path) {
            try fileManager.removeItem(at: quarantinedFileURL)
        }
        if recovery != nil, fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        for artifact in quarantineArtifactURLs() where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
        if fileManager.fileExists(atPath: recoveryURL.path) {
            try fileManager.removeItem(at: recoveryURL)
        }
    }

    private var recoveryURL: URL {
        url.appendingPathExtension("recovery")
    }

    private func decodeState() throws -> WorkspaceStateFile {
        try JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: Data(contentsOf: url)).validated()
    }

    private func checkpointLoaded(_ state: WorkspaceStateFile) throws {
        try store.write(try state.validated(), to: url)
    }

    private func readRecoveryState() -> WorkspaceRecoveryState? {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return nil }
        if let recovery = try? JSONDecoder.workspace.decode(WorkspaceRecoveryState.self, from: Data(contentsOf: recoveryURL)) {
            return recovery
        }
        return WorkspaceRecoveryState(
            originalFilePath: url.path,
            quarantinedFilePath: quarantineArtifactURL()?.path,
            message: "The Workspace recovery marker is unreadable."
        )
    }

    private func recoveryFromQuarantineArtifact() -> WorkspaceRecoveryState? {
        guard let artifact = quarantineArtifactURL() else { return nil }
        return WorkspaceRecoveryState(
            originalFilePath: url.path,
            quarantinedFilePath: artifact.path,
            message: "Workspace state was quarantined without a readable recovery marker."
        )
    }

    private func quarantineArtifactURL() -> URL? {
        quarantineArtifactURLs().first
    }

    private func quarantineArtifactURLs() -> [URL] {
        let prefix = "\(url.lastPathComponent).broken-"
        return (try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) }) ?? []
    }

    private func quarantine(error: Error) -> WorkspaceRecoveryState {
        let candidateURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).broken-\(UUID().uuidString)"
        )
        let quarantinedURL: URL?
        do {
            try FileManager.default.moveItem(at: url, to: candidateURL)
            quarantinedURL = candidateURL
        } catch {
            quarantinedURL = nil
        }
        let recovery = WorkspaceRecoveryState(
            originalFilePath: url.path,
            quarantinedFilePath: quarantinedURL?.path,
            message: String(describing: error)
        )
        try? store.write(recovery, to: recoveryURL)
        return recovery
    }
}
