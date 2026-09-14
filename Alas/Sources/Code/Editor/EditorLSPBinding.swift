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
    var sourceGeneration: Int? = nil
    var bindingID: UUID? = nil
    var bufferID: ObjectIdentifier? = nil
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
    private let holderRoot: URL
    private let identity = UUID()
    private var active = true
    private let flushPendingChanges: @MainActor () async -> Void

    init(
        manager: WorkspaceLSPManager,
        buffer: EditorBuffer,
        worktreeID: String,
        holderRoot: URL? = nil,
        flushPendingChanges: @escaping @MainActor () async -> Void = {}
    ) {
        self.manager = manager
        self.buffer = buffer
        self.worktreeID = worktreeID
        self.holderRoot = holderRoot ?? buffer.worktreeRoot
        self.flushPendingChanges = flushPendingChanges
    }

    func synchronize(range: NSRange) async throws -> EditorRequestContext {
        guard active, let buffer else { throw Error.documentNotOpen }
        let generation = buffer.editGeneration
        await flushPendingChanges()
        guard active, buffer.editGeneration == generation else { throw Error.documentNotOpen }
        let text = buffer.storage.string
        guard let lspRange = TextEditCoordinates.lspRange(for: range, in: text) else {
            throw Error.invalidRange
        }
        let fileURL = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        guard var context = await manager.requestContext(
            forFile: fileURL,
            worktreeRoot: holderRoot,
            worktreeID: worktreeID,
            range: lspRange
        ) else {
            throw Error.documentNotOpen
        }
        context.sourceGeneration = generation
        context.bindingID = identity
        context.bufferID = ObjectIdentifier(buffer)
        guard isCurrent(context) else { throw Error.documentNotOpen }
        return context
    }

    func isCurrent(_ context: EditorRequestContext) -> Bool {
        guard active, let buffer else { return false }
        return context.bindingID == identity
            && context.sourceGeneration == buffer.editGeneration
            && context.document.worktreeID == worktreeID
            && context.document.uri == buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI
            && context.document.host == RemoteHostRegistry.shared.host(forPath: holderRoot.path)
            && manager.isCurrent(context)
    }

    func invalidate() { active = false }

    func synchronizeRequest(range: NSRange, language: String) async -> (LSPClient, EditorRequestContext)? {
        guard let context = try? await synchronize(range: range),
              isCurrent(context),
              let client = openedClient(language: language) else {
            return nil
        }
        return (client, context)
    }

    func openedClient(language: String) -> LSPClient? {
        guard active, let buffer else { return nil }
        let fileURL = buffer.worktreeRoot.appendingPathComponent(buffer.relativePath)
        return manager.openedClient(forFile: fileURL, worktreeRoot: holderRoot, language: language)
    }
}
