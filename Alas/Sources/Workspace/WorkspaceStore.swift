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
        if let recovery = recoveryFromQuarantineArtifact() {
            return .unreadable(recovery)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            return .loaded(try decodeState())
        } catch {
            return .unreadable(quarantine(error: error))
        }
    }

    func checkpoint(_ state: WorkspaceStateFile) throws {
        if case .unreadable = load() {
            throw WorkspaceStoreError.recoveryRequired
        }
        try store.write(try state.validated(), to: url)
    }

    func discardUnreadableState() throws {
        try? FileManager.default.removeItem(at: recoveryURL)
    }

    private var recoveryURL: URL {
        url.appendingPathExtension("recovery")
    }

    private func decodeState() throws -> WorkspaceStateFile {
        try JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: Data(contentsOf: url)).validated()
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
        let prefix = "\(url.lastPathComponent).broken-"
        return try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .first(where: { $0.lastPathComponent.hasPrefix(prefix) })
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
