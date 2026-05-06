import Foundation
import Observation

@Observable
final class WorkspaceLSPManager {
    private struct Key: Hashable { let root: String; let language: String }

    /// One holder per `(worktreeRoot, language)`. Inserted **before**
    /// awaiting `initialize()` so a concurrent `closeDocument` can find it
    /// and update state in flight.
    ///
    /// `refsByURI` tracks the user's open intent **per file** — the codex
    /// scenario being: file A starts the server, file B opens during init
    /// (sees existing holder, registers its URI), file A closes during
    /// init. With aggregate ref counting the holder still has refCount=1
    /// (B), so A's resumed open path would happily send `didOpen` for the
    /// already-closed A. With per-URI counts, A's resume sees `refsByURI[A]`
    /// is gone and skips `didOpen`, while B proceeds normally.
    ///
    /// `openedURIs` records URIs for which `didOpen` was actually delivered,
    /// so `closeDocument` only sends `didClose` when there's something
    /// matching to close on the server side.
    ///
    /// `ready` is a one-shot Task that returns `true` when initialize
    /// succeeded and `false` on failure; both open and close await it
    /// before sending notifications.
    private struct Holder {
        let client: LSPClient
        let ready: Task<Bool, Never>
        var refsByURI: [String: Int]
        var openedURIs: Set<String>
    }

    private var holders: [Key: Holder] = [:]
    private let registry: LanguageServerRegistry

    init(registry: LanguageServerRegistry) {
        self.registry = registry
    }

    /// Register an open editor tab for `(worktreeRoot, fileURL)`. Spawns
    /// the language server if needed and sends `didOpen` once
    /// initialization completes — unless `closeDocument` for the same
    /// `fileURL` arrived during initialization, in which case the open is
    /// abandoned without notifying the server. Returns the client (or nil
    /// when no server is configured, init failed, or the document was
    /// closed before init completed).
    @discardableResult
    func openDocument(worktreeRoot: URL, fileURL: URL, languageId: String, text: String) async -> LSPClient? {
        let key = Key(root: worktreeRoot.path, language: languageId)
        let uri = fileURL.lspURI
        let client: LSPClient
        let ready: Task<Bool, Never>
        if let existing = holders[key] {
            var refs = existing.refsByURI
            refs[uri, default: 0] += 1
            holders[key] = Holder(client: existing.client, ready: existing.ready, refsByURI: refs, openedURIs: existing.openedURIs)
            client = existing.client
            ready = existing.ready
        } else {
            guard let entry = registry.entry(forLanguage: languageId) else { return nil }
            let spawn = Self.resolveSpawn(command: entry.command, args: entry.args)
            let transport = LSPTransport(executable: spawn.executable, arguments: spawn.arguments, environment: entry.env.isEmpty ? nil : entry.env)
            let newClient = LSPClient(transport: transport, language: languageId, rootURI: worktreeRoot.lspURI)
            let task = Task<Bool, Never> {
                do { try await newClient.initialize(); return true } catch { return false }
            }
            holders[key] = Holder(client: newClient, ready: task, refsByURI: [uri: 1], openedURIs: [])
            client = newClient
            ready = task
        }

        let initOk = await ready.value
        if !initOk {
            // Init failed — drop the dead holder. The first awaiter to wake
            // wins; subsequent ones see it's already gone.
            holders.removeValue(forKey: key)
            return nil
        }

        // Did this specific file's last ref get dropped while we waited?
        guard let h = holders[key], (h.refsByURI[uri] ?? 0) > 0 else {
            // The file was closed during init. If the *whole* holder is
            // also refless (no other tabs), shut the server down.
            if let cur = holders[key], cur.refsByURI.isEmpty {
                await client.shutdown()
                holders.removeValue(forKey: key)
            }
            return nil
        }

        // Send `didOpen` exactly once per URI. Mark the URI as opened
        // *before* sending so a close racing with the in-flight notification
        // sees the marker and balances with `didClose` rather than dropping it.
        if !h.openedURIs.contains(uri) {
            if var holder = holders[key] {
                holder.openedURIs.insert(uri)
                holders[key] = holder
            }
            try? await client.didOpen(
                uri: uri,
                languageId: languageId,
                version: 1,
                text: text
            )
        }
        return client
    }

    func closeDocument(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        let key = Key(root: worktreeRoot.path, language: languageId)
        let uri = fileURL.lspURI
        guard var holder = holders[key], (holder.refsByURI[uri] ?? 0) > 0 else { return }
        var refs = holder.refsByURI
        let newRef = (refs[uri] ?? 0) - 1
        if newRef <= 0 {
            refs.removeValue(forKey: uri)
        } else {
            refs[uri] = newRef
        }
        holder.refsByURI = refs
        holders[key] = holder

        let initOk = await holder.ready.value
        guard let cur = holders[key] else { return }
        if !initOk { return }

        // Other tabs still need this file open — nothing to send.
        if (cur.refsByURI[uri] ?? 0) > 0 { return }

        // File is fully closed. Send `didClose` if the matching `didOpen`
        // was actually delivered; otherwise the server has nothing to forget.
        if cur.openedURIs.contains(uri) {
            try? await cur.client.didClose(uri: uri)
            if var c = holders[key] {
                c.openedURIs.remove(uri)
                holders[key] = c
            }
        }

        // Shut down the server if no files remain on it.
        if let c = holders[key], c.refsByURI.isEmpty {
            await c.client.shutdown()
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
