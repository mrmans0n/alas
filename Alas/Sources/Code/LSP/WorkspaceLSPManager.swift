import Foundation
import Observation

@Observable
final class WorkspaceLSPManager {
    private struct Key: Hashable { let root: String; let language: String }

    /// One holder per `(worktreeRoot, language)`. The holder is inserted
    /// **before** awaiting `initialize()` so a concurrent `closeDocument`
    /// can still find it and decrement `refCount` — otherwise the close
    /// would no-op and the open path would resume to insert a holder for
    /// a document that no longer has a tab, leaving a stale server alive.
    /// `ready` is a one-shot Task that returns `true` when initialize
    /// succeeded and `false` on failure; both open and close await it
    /// before sending notifications.
    private struct Holder {
        let client: LSPClient
        var refCount: Int
        let ready: Task<Bool, Never>
    }

    private var holders: [Key: Holder] = [:]
    private let registry: LanguageServerRegistry

    init(registry: LanguageServerRegistry) {
        self.registry = registry
    }

    /// Register an open editor tab for `(worktreeRoot, fileURL)`. Spawns
    /// the language server if needed and sends `didOpen`. Returns the
    /// client (or nil if no server is configured for the language, the
    /// server failed to initialize, or the document was closed before
    /// initialization completed).
    @discardableResult
    func openDocument(worktreeRoot: URL, fileURL: URL, languageId: String, text: String) async -> LSPClient? {
        let key = Key(root: worktreeRoot.path, language: languageId)
        let client: LSPClient
        let ready: Task<Bool, Never>
        let isFirstOpener: Bool
        if let existing = holders[key] {
            holders[key] = Holder(client: existing.client, refCount: existing.refCount + 1, ready: existing.ready)
            client = existing.client
            ready = existing.ready
            isFirstOpener = false
        } else {
            guard let entry = registry.entry(forLanguage: languageId) else { return nil }
            let spawn = Self.resolveSpawn(command: entry.command, args: entry.args)
            let transport = LSPTransport(executable: spawn.executable, arguments: spawn.arguments, environment: entry.env.isEmpty ? nil : entry.env)
            let newClient = LSPClient(transport: transport, language: languageId, rootURI: worktreeRoot.lspURI)
            let task = Task<Bool, Never> {
                do { try await newClient.initialize(); return true } catch { return false }
            }
            holders[key] = Holder(client: newClient, refCount: 1, ready: task)
            client = newClient
            ready = task
            isFirstOpener = true
        }
        let initOk = await ready.value
        if !initOk {
            // Init failed. The first opener owns the holder; remove it so a
            // future open spawns a fresh client instead of reusing this one.
            // Subsequent openers see the holder is already gone (or will be)
            // and just bail.
            if isFirstOpener { holders.removeValue(forKey: key) }
            return nil
        }
        // Init succeeded. If a close raced ahead and dropped the last ref
        // while we were waiting, shut the server down and don't send didOpen
        // for a document that no longer has a tab.
        guard let holder = holders[key], holder.refCount > 0 else {
            if isFirstOpener {
                await client.shutdown()
                holders.removeValue(forKey: key)
            }
            return nil
        }
        try? await client.didOpen(
            uri: fileURL.lspURI,
            languageId: languageId,
            version: 1,
            text: text
        )
        return client
    }

    func closeDocument(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        let key = Key(root: worktreeRoot.path, language: languageId)
        guard let holder = holders[key] else { return }
        let newCount = holder.refCount - 1
        holders[key] = Holder(client: holder.client, refCount: newCount, ready: holder.ready)
        let initOk = await holder.ready.value
        // Re-fetch in case the open path observed refCount==0 during our
        // await of `ready` and already shut down + removed the holder, or
        // a new open arrived and re-incremented refCount.
        guard let cur = holders[key] else { return }
        if !initOk {
            // Init failed; let the open path's failure branch own the
            // removal so we don't double-remove.
            return
        }
        try? await cur.client.didClose(uri: fileURL.lspURI)
        if cur.refCount <= 0 {
            await cur.client.shutdown()
            holders.removeValue(forKey: key)
        }
    }

    func client(forWorktree root: URL, language: String) -> LSPClient? {
        holders[Key(root: root.path, language: language)]?.client
    }

    /// Maps a file extension to its configured language id, or nil if no
    /// enabled server claims that extension. Delegates to the registry so
    /// user-defined entries (Settings → Code) are honored.
    func language(forFileExtension ext: String) -> String? {
        registry.language(forFileExtension: ext)
    }

    // MARK: - Spawn resolution

    private struct Spawn {
        let executable: URL
        let arguments: [String]
    }

    /// `Process.executableURL` does not search `PATH`. If `command` contains
    /// no `/` (e.g. `rust-analyzer`, `sourcekit-lsp`), we wrap the call with
    /// `/usr/bin/env` so the system path is searched at exec time —
    /// otherwise users entering bare command names in Settings → Code would
    /// silently fail unless their cwd happened to contain the binary.
    private static func resolveSpawn(command: String, args: [String]) -> Spawn {
        if command.contains("/") {
            return Spawn(executable: URL(fileURLWithPath: command), arguments: args)
        }
        return Spawn(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [command] + args)
    }
}
