import Foundation

struct EditorDocumentID: Hashable, Sendable, Codable {
    let host: String?
    let worktreeID: String
    let uri: String
}

struct EditorRequestContext: Equatable, Sendable {
    let document: EditorDocumentID
    let version: Int
    let serverGeneration: UUID
    let range: LSPRange
}

@MainActor
final class EditorLSPBinding {
    enum Error: Swift.Error {
        case invalidRange
        case documentNotOpen
    }

    private let manager: WorkspaceLSPManager
    private weak var buffer: EditorBuffer?
    private let worktreeID: String
    private let flushPendingChanges: @MainActor () async -> Void

    init(
        manager: WorkspaceLSPManager,
        buffer: EditorBuffer,
        worktreeID: String,
        flushPendingChanges: @escaping @MainActor () async -> Void = {}
    ) {
        self.manager = manager
        self.buffer = buffer
        self.worktreeID = worktreeID
        self.flushPendingChanges = flushPendingChanges
    }

    func synchronize(range: NSRange) async throws -> EditorRequestContext {
        guard let buffer else { throw Error.documentNotOpen }
        await flushPendingChanges()
        let text = buffer.storage.string
        guard let lspRange = TextEditCoordinates.lspRange(for: range, in: text) else {
            throw Error.invalidRange
        }
        let fileURL = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        guard let context = await manager.requestContext(
            forFile: fileURL,
            worktreeRoot: buffer.worktreeRoot,
            worktreeID: worktreeID,
            range: lspRange
        ) else {
            throw Error.documentNotOpen
        }
        return context
    }

    func isCurrent(_ context: EditorRequestContext) -> Bool {
        manager.isCurrent(context)
    }

    func synchronizeRequest(range: NSRange, language: String) async -> (LSPClient, EditorRequestContext)? {
        guard let context = try? await synchronize(range: range),
              isCurrent(context),
              let client = openedClient(language: language) else {
            return nil
        }
        return (client, context)
    }

    func openedClient(language: String) -> LSPClient? {
        guard let buffer else { return nil }
        let fileURL = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        return manager.openedClient(forFile: fileURL, worktreeRoot: buffer.worktreeRoot, language: language)
    }
}
