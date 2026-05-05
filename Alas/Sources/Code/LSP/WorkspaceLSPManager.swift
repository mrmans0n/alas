import Foundation
import Observation

@Observable
final class WorkspaceLSPManager {
    private struct Key: Hashable { let root: String; let language: String }
    private struct Holder {
        let client: LSPClient
        var refCount: Int
    }

    private var holders: [Key: Holder] = [:]
    private let registry: LanguageServerRegistry

    init(registry: LanguageServerRegistry) {
        self.registry = registry
    }

    /// Register an open editor tab for `(worktreeRoot, fileURL)`. Spawns
    /// the language server if needed and sends `didOpen`. Returns the
    /// client (or nil if no server is configured for the language).
    @discardableResult
    func openDocument(worktreeRoot: URL, fileURL: URL, languageId: String, text: String) async -> LSPClient? {
        let key = Key(root: worktreeRoot.path, language: languageId)
        let client: LSPClient
        if let existing = holders[key] {
            holders[key] = Holder(client: existing.client, refCount: existing.refCount + 1)
            client = existing.client
        } else {
            guard let entry = registry.entry(forLanguage: languageId) else { return nil }
            let exec = URL(fileURLWithPath: entry.command)
            let transport = LSPTransport(executable: exec, arguments: entry.args, environment: entry.env.isEmpty ? nil : entry.env)
            let new = LSPClient(transport: transport, language: languageId,
                                rootURI: "file://" + worktreeRoot.path)
            do { try await new.initialize() } catch { return nil }
            holders[key] = Holder(client: new, refCount: 1)
            client = new
        }
        try? await client.didOpen(
            uri: "file://" + fileURL.path,
            languageId: languageId,
            version: 1,
            text: text
        )
        return client
    }

    func closeDocument(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        let key = Key(root: worktreeRoot.path, language: languageId)
        guard let holder = holders[key] else { return }
        try? await holder.client.didClose(uri: "file://" + fileURL.path)
        let newCount = holder.refCount - 1
        if newCount <= 0 {
            await holder.client.shutdown()
            holders.removeValue(forKey: key)
        } else {
            holders[key] = Holder(client: holder.client, refCount: newCount)
        }
    }

    func client(forWorktree root: URL, language: String) -> LSPClient? {
        holders[Key(root: root.path, language: language)]?.client
    }
}
