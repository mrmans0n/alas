import Foundation
import Observation

extension Notification.Name {
    /// Posted from `WorkspaceLSPManager` when a language server spawn was
    /// skipped because the resolved binary is blocked by Gatekeeper.
    /// userInfo: ["language": String, "realPath": String].
    static let lspBlockedByGatekeeper = Notification.Name("lspBlockedByGatekeeper")
}

@MainActor
protocol DocumentFormatter: AnyObject {
    func language(forFileExtension ext: String) -> String?
    func language(forPath path: String) -> String?
    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]?
    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]?) async
}

extension DocumentFormatter {
    /// Reduces the path to its lookup key and defers to the extension-based
    /// requirement, so a conformance only has to implement one of the two.
    func language(forPath path: String) -> String? {
        language(forFileExtension: LanguageServerRegistry.extensionKey(forPath: path))
    }
}

@Observable
@MainActor
final class WorkspaceLSPManager: DocumentFormatter {
    /// Identifies a holder by the resolved spawn (root + command + args +
    /// env) rather than the LSP languageId. typescript-language-server
    /// requires per-extension language IDs (`typescript`, `typescriptreact`,
    /// `javascript`, `javascriptreact`), but they all point at the same
    /// binary and a single instance handles cross-file references and
    /// unsaved buffers across the whole project. Keying on the languageId
    /// would split them into 4 isolated servers and stale-out cross-file
    /// hover/diagnostics/definitions for unsaved edits. `env` is part of
    /// the identity because two configs that share root+command+args but
    /// pin different `PATH` / variables must still launch separate
    /// processes — a user override won't be silently merged onto the
    /// first match's environment.
    private struct Key: Hashable {
        let root: String
        let command: String
        let args: [String]
        let env: [String: String]
    }

    /// One holder per `(worktreeRoot, language)`. Inserted **before**
    /// awaiting `initialize()` so a concurrent `closeDocument` can find it
    /// and update state in flight.
    ///
    /// `refsByURI` tracks total open intent **per file**. Editor-owned refs
    /// and temporary read-only refs both keep the URI open on the server,
    /// while `temporaryRefsByURI` records the temporary subset so editor
    /// opens can replace temporary disk text and closes only release the
    /// ownership they actually hold. The codex scenario being: file A starts
    /// the server, file B opens during init (sees existing holder, registers
    /// its URI), file A closes during init. With aggregate ref counting the
    /// holder still has refCount=1 (B), so A's resumed open path would
    /// happily send `didOpen` for the already-closed A. With per-URI counts,
    /// A's resume sees `refsByURI[A]` is gone and skips `didOpen`, while B
    /// proceeds normally.
    ///
    /// `openedURIs` records URIs for which `didOpen` was actually delivered,
    /// so `closeDocument` only sends `didClose` when there's something
    /// matching to close on the server side.
    ///
    /// `ready` is a one-shot Task that returns `true` when initialize
    /// succeeded and `false` on failure; both open and close await it
    /// before sending notifications.
    private enum HolderLifeState { case starting, ready, dead }

    private struct Holder {
        let client: LSPClient
        let ready: Task<Bool, Never>
        var refsByURI: [String: Int]
        var temporaryRefsByURI: [String: Int]
        var temporaryTextsByURI: [String: String]
        var openedURIs: Set<String>
        var versions: [String: Int]   // last didChange version per URI
        var pendingOpenText: [String: String]  // latest text supplied to a not-yet-sent didOpen
        var texts: [String: String]  // last text version sent to the server per URI
        // One holder can serve multiple LSP languageIds (typescript-language-server
        // serves typescript/typescriptreact/javascript/javascriptreact under a
        // single binary). Per-URI tracking lets `restartHolder` reopen each
        // file with the languageId it was originally opened under, instead
        // of forcing every file onto the languageId of the tab that
        // triggered the restart.
        var languagesByURI: [String: String]
        var lifeState: HolderLifeState
    }

    private enum DocumentOwnership {
        case editor
        case temporary
    }

    /// Coarse status of a document's serving holder. The resolver folds this
    /// into `EditorLSPStatus.loading` (.none and .loading), `.ready`, or
    /// `.problem(.dead)`.
    enum DocumentStatus: Equatable {
        case none
        case loading
        case ready
        case dead
    }

    private var holders: [Key: Holder] = [:]
    private var pendingOpenRefs: [Key: [String: Int]] = [:]
    private var pendingTemporaryOpenRefs: [Key: [String: Int]] = [:]

    /// Bumping counter that lets `@Observable` consumers (the status badge)
    /// re-run derivations when a holder transitions starting → ready → dead.
    /// Incremented under `@MainActor` so SwiftUI sees changes without a hop.
    private(set) var stateTick: Int = 0

    private func bumpStateTick() { stateTick &+= 1 }

    private var registry: LanguageServerRegistry
    private let makeClient: (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ language: String, _ rootURI: String) -> LSPClient

    /// Cached per-language availability so the status badge doesn't re-run
    /// `LanguageServerAvailability.status(for:)` on every SwiftUI breadcrumb
    /// re-render. Swift `sourcekit-lsp` can fall back to a bounded `xcrun
    /// --find` probe, so render-adjacent callers should still reuse the cached
    /// result. Cleared whenever the registry changes (the only thing that can
    /// change the answer).
    private let makeAvailability: () -> LanguageServerAvailability
    private var cachedAvailability: LanguageServerAvailability
    private var availabilityCache: [String: LanguageServerAvailability.Status] = [:]

    init(
        registry: LanguageServerRegistry,
        makeAvailability: @escaping () -> LanguageServerAvailability = { LanguageServerAvailability() },
        makeClient: @escaping (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ language: String, _ rootURI: String) -> LSPClient = { executable, arguments, environment, language, rootURI in
            LSPClient(
                transport: LSPTransport(executable: executable, arguments: arguments, environment: environment),
                language: language,
                rootURI: rootURI
            )
        }
    ) {
        self.registry = registry
        self.makeAvailability = makeAvailability
        self.cachedAvailability = makeAvailability()
        self.makeClient = makeClient
    }

    func updateRegistry(_ registry: LanguageServerRegistry) {
        self.registry = registry
        cachedAvailability = makeAvailability()
        availabilityCache.removeAll()
    }

    /// Returns the cached availability status for `language`, falling back
    /// to a single `LanguageServerAvailability.status(for:)` probe and
    /// caching the result. Designed for hot-path callers like the status
    /// badge resolver.
    ///
    /// Missing Swift `sourcekit-lsp` is cached too: that resolution can still
    /// fall back to bounded `xcrun --find`, so negative results must not be
    /// re-probed from render-adjacent status badge paths. Other
    /// `.notInstalled` statuses continue to re-probe so manual installs outside
    /// Alas are picked up.
    /// Runtime installs explicitly invalidate the language below.
    /// `.blockedByGatekeeper` still re-probes because remediation can flip
    /// without changing the registry.
    func availabilityStatus(forLanguage language: String) -> LanguageServerAvailability.Status? {
        if let cached = availabilityCache[language] { return cached }
        guard let entry = registry.allEntries().first(where: { $0.language == language }) else { return nil }
        let status = cachedAvailability.status(for: entry)
        if shouldCacheAvailabilityStatus(status, for: entry) {
            availabilityCache[language] = status
        }
        return status
    }

    private func shouldCacheAvailabilityStatus(
        _ status: LanguageServerAvailability.Status,
        for entry: LanguageServerConfig
    ) -> Bool {
        switch status {
        case .available, .disabled:
            return true
        case .notInstalled:
            return entry.language == "swift" && entry.command == "sourcekit-lsp"
        case .blockedByGatekeeper:
            return false
        }
    }

    func invalidateAvailabilityCache(forLanguage language: String) {
        let languages = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: language))
        availabilityCache = availabilityCache.filter { !languages.contains($0.key) }
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
        await openDocument(worktreeRoot: worktreeRoot, fileURL: fileURL, languageId: languageId, text: text, ownership: .editor)
    }

    @discardableResult
    func openTemporaryDocument(worktreeRoot: URL, fileURL: URL, languageId: String, text: String) async -> LSPClient? {
        await openDocument(worktreeRoot: worktreeRoot, fileURL: fileURL, languageId: languageId, text: text, ownership: .temporary)
    }

    @discardableResult
    private func openDocument(
        worktreeRoot: URL,
        fileURL: URL,
        languageId: String,
        text: String,
        ownership: DocumentOwnership
    ) async -> LSPClient? {
        guard let entry = registry.entry(forLanguage: languageId) else { return nil }
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktreeRoot.path)
        let lspRoot: URL
        if let remoteHost {
            lspRoot = await Self.resolveRemoteLSPRoot(
                fileURL: fileURL,
                worktreeRoot: worktreeRoot,
                markers: entry.rootMarkers,
                host: remoteHost
            )
        } else {
            lspRoot = Self.resolveLSPRoot(fileURL: fileURL, worktreeRoot: worktreeRoot, markers: entry.rootMarkers)
        }
        let key = Key(root: lspRoot.path, command: entry.command, args: entry.args, env: entry.env)
        let uri = fileURL.lspURI
        var shouldReplaceTemporaryText = false
        // If a previous holder's server died (process exited, transport
        // closed) we'd otherwise reuse the dead client and silently fail to
        // deliver hover/diagnostics/definition until the user closed every
        // tab for that language. Drop the dead holder and fall through to
        // spawn a fresh one. Identity-check the dictionary entry before
        // removing, so we don't clobber a holder another task already
        // swapped in while we were awaiting the state read.
        if let existing = holders[key] {
            let dead = await existing.client.state == .dead
            if dead, let cur = holders[key], cur.client === existing.client {
                holders.removeValue(forKey: key)
                bumpStateTick()
            }
        }
        let client: LSPClient
        let ready: Task<Bool, Never>
        let isFirstOpener: Bool
        if let existing = holders[key] {
            var refs = existing.refsByURI
            refs[uri, default: 0] += 1
            var temporaryRefs = existing.temporaryRefsByURI
            if ownership == .temporary {
                temporaryRefs[uri, default: 0] += 1
            } else if existing.openedURIs.contains(uri),
                      normalRefCount(forURI: uri, in: existing) == 0,
                      (existing.temporaryRefsByURI[uri] ?? 0) > 0 {
                shouldReplaceTemporaryText = true
            }
            // Record this open's text as the latest pending — if `didOpen`
            // hasn't been sent yet, whichever awaiter wakes first will read
            // this value rather than the stale `text` captured on a prior
            // call. (Codex case: tab closed and reopened with different
            // content while the server was still initializing.)
            holders[key] = holderByUpdatingRefs(
                existing,
                uri: uri,
                text: text,
                refs: refs,
                temporaryRefs: temporaryRefs,
                ownership: ownership
            )
            client = existing.client
            ready = existing.ready
            isFirstOpener = false
        } else {
            addPendingOpenRef(key: key, uri: uri, ownership: ownership)
            let availability = makeAvailability()
            if let remoteHost {
                guard await RemoteLSPLauncher.isAvailable(command: entry.command, host: remoteHost, env: entry.env) else {
                    _ = consumePendingOpenRef(key: key, uri: uri, ownership: ownership)
                    return nil
                }
            } else {
                switch await availability.statusRemediatingGatekeeper(for: entry) {
                case .disabled, .notInstalled:
                    _ = consumePendingOpenRef(key: key, uri: uri, ownership: ownership)
                    return nil
                case .blockedByGatekeeper(let realPath):
                    _ = consumePendingOpenRef(key: key, uri: uri, ownership: ownership)
                    NotificationCenter.default.post(
                        name: .lspBlockedByGatekeeper,
                        object: nil,
                        userInfo: ["language": entry.language, "realPath": realPath]
                    )
                    return nil
                case .available:
                    break
                }
            }
            guard consumePendingOpenRef(key: key, uri: uri, ownership: ownership) else { return nil }
            if let existing = holders[key] {
                var refs = existing.refsByURI
                refs[uri, default: 0] += 1
                var temporaryRefs = existing.temporaryRefsByURI
                if ownership == .temporary {
                    temporaryRefs[uri, default: 0] += 1
                } else if existing.openedURIs.contains(uri),
                          normalRefCount(forURI: uri, in: existing) == 0,
                          (existing.temporaryRefsByURI[uri] ?? 0) > 0 {
                    shouldReplaceTemporaryText = true
                }
                holders[key] = holderByUpdatingRefs(
                    existing,
                    uri: uri,
                    text: text,
                    refs: refs,
                    temporaryRefs: temporaryRefs,
                    ownership: ownership
                )
                client = existing.client
                ready = existing.ready
                isFirstOpener = false
            } else {
                let spawn = Self.resolveSpawn(
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    language: entry.language,
                    availability: availability,
                    remoteHost: remoteHost,
                    rootPath: lspRoot.path
                )
                let newClient = makeClient(spawn.executable, spawn.arguments, spawn.environment, languageId, lspRoot.lspURI)
                let task = Task<Bool, Never> {
                    do { try await newClient.initialize()
                    return true } catch { return false }
                }
                holders[key] = Holder(
                    client: newClient,
                    ready: task,
                    refsByURI: [uri: 1],
                    temporaryRefsByURI: ownership == .temporary ? [uri: 1] : [:],
                    temporaryTextsByURI: ownership == .temporary ? [uri: text] : [:],
                    openedURIs: [],
                    versions: [:],
                    pendingOpenText: [uri: text],
                    texts: [:],
                    languagesByURI: [:],
                    lifeState: .starting
                )
                bumpStateTick()
                client = newClient
                ready = task
                isFirstOpener = true
            }
        }

        let initOk = await ready.value
        if var h = holders[key], h.client === client {
            h.lifeState = initOk ? .ready : .dead
            holders[key] = h
            bumpStateTick()
        }
        if !initOk {
            // Init failed. The opener that spawned the client owns the
            // shutdown call to release the failed `Process`. Leave the
            // holder entry in place with `lifeState = .dead` so the badge
            // can show "problem" and offer "Restart" — removing the holder
            // here would make `documentStatus` report `.none`, indistinguishable
            // from "never opened". `restartHolder` is the proper cleanup path.
            if isFirstOpener {
                await client.shutdown()
            }
            return nil
        }

        // Did this specific file's last ref get dropped while we waited?
        guard let h = holders[key], h.client === client, (h.refsByURI[uri] ?? 0) > 0 else {
            // The file was closed during init (or another task replaced
            // the holder). If our spawned client is no longer the live
            // one, just walk away. If it is and the whole holder is
            // refless, shut it down once.
            if let cur = holders[key], cur.client === client, cur.refsByURI.isEmpty {
                await client.shutdown()
                holders.removeValue(forKey: key)
            }
            return nil
        }

        // Send `didOpen` exactly once per URI. Mark the URI as opened
        // *before* sending so a close racing with the in-flight notification
        // sees the marker and balances with `didClose` rather than dropping
        // it. We pull `text` from `pendingOpenText` (updated synchronously
        // by every `openDocument` call before its await) so a later opener's
        // newer content wins even if an earlier opener's continuation
        // resumes first.
        if !h.openedURIs.contains(uri) {
            let openText: String
            if normalRefCount(forURI: uri, in: h) == 0,
               (h.temporaryRefsByURI[uri] ?? 0) > 0,
               let temporaryText = h.temporaryTextsByURI[uri] {
                openText = temporaryText
            } else {
                openText = h.pendingOpenText[uri] ?? text
            }
            if var holder = holders[key] {
                holder.openedURIs.insert(uri)
                holder.versions[uri] = 1
                holder.pendingOpenText.removeValue(forKey: uri)
                holder.texts[uri] = openText
                holder.languagesByURI[uri] = languageId
                holders[key] = holder
                bumpStateTick()
            }
            try? await client.didOpen(
                uri: uri,
                languageId: languageId,
                version: 1,
                text: openText
            )
        } else if shouldReplaceTemporaryText {
            if var holder = holders[key], holder.client === client, holder.openedURIs.contains(uri) {
                let nextVersion = (holder.versions[uri] ?? 1) + 1
                let previousText = holder.texts[uri]
                holder.versions[uri] = nextVersion
                holder.texts[uri] = text
                holder.languagesByURI[uri] = languageId
                holders[key] = holder
                try? await client.didChange(
                    uri: uri,
                    version: nextVersion,
                    text: text,
                    previousText: previousText
                )
            }
        }
        return client
    }

    /// Apply new content for an open or pending document. If `didOpen` has
    /// already been delivered, sends `textDocument/didChange` with a fresh
    /// version. If the holder exists but the server is still initializing
    /// (so no `didOpen` has gone out yet), updates `pendingOpenText` so the
    /// delayed `didOpen` carries the latest content — otherwise we'd lose
    /// the reload and the server would analyze the stale tab-open snapshot.
    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]? = nil) async {
        let uri = fileURL.lspURI
        // Look up by URI instead of recomputing the key from the current
        // entry: if the user edited the registry (command/args/env) after
        // the file was opened, the original holder lives under the old key
        // and a recomputed lookup would miss it, leaking the server.
        guard let key = holderKey(forURI: uri), var holder = holders[key] else { return }
        if !holder.openedURIs.contains(uri) {
            // Server still in `initialize()`. Update the pending text so the
            // suspended `openDocument` reads the new value when it resumes.
            guard (holder.refsByURI[uri] ?? 0) > 0 else { return }
            holder.pendingOpenText[uri] = text
            holders[key] = holder
            return
        }
        let initOk = await holder.ready.value
        guard initOk else { return }
        guard var cur = holders[key], cur.openedURIs.contains(uri) else { return }
        let nextVersion = (cur.versions[uri] ?? 1) + 1
        let previousText = cur.texts[uri]
        cur.versions[uri] = nextVersion
        cur.texts[uri] = text
        holders[key] = cur
        try? await cur.client.didChange(uri: uri, version: nextVersion, text: text, previousText: previousText, edits: edits)
    }

    func closeDocument(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        await closeDocument(worktreeRoot: worktreeRoot, fileURL: fileURL, languageId: languageId, ownership: .editor)
    }

    func closeTemporaryDocument(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        await closeDocument(worktreeRoot: worktreeRoot, fileURL: fileURL, languageId: languageId, ownership: .temporary)
    }

    private func closeDocument(
        worktreeRoot: URL,
        fileURL: URL,
        languageId: String,
        ownership: DocumentOwnership
    ) async {
        let uri = fileURL.lspURI
        // See `didChange` — find the holder by URI so registry edits made
        // after the open don't strand the original server.
        guard let key = holderKey(forURI: uri), var holder = holders[key], (holder.refsByURI[uri] ?? 0) > 0 else {
            _ = consumePendingOpenRef(forURI: uri, withinWorktreeRoot: worktreeRoot, ownership: ownership)
            return
        }
        var refs = holder.refsByURI
        var temporaryRefs = holder.temporaryRefsByURI
        switch ownership {
        case .editor:
            guard normalRefCount(forURI: uri, in: holder) > 0 else {
                _ = consumePendingOpenRef(forURI: uri, withinWorktreeRoot: worktreeRoot, ownership: ownership)
                return
            }
        case .temporary:
            guard (temporaryRefs[uri] ?? 0) > 0 else {
                _ = consumePendingOpenRef(forURI: uri, withinWorktreeRoot: worktreeRoot, ownership: ownership)
                return
            }
            let newTemporaryRef = (temporaryRefs[uri] ?? 0) - 1
            if newTemporaryRef <= 0 {
                temporaryRefs.removeValue(forKey: uri)
            } else {
                temporaryRefs[uri] = newTemporaryRef
            }
        }
        let newRef = (refs[uri] ?? 0) - 1
        if newRef <= 0 {
            refs.removeValue(forKey: uri)
        } else {
            refs[uri] = newRef
        }
        holder.refsByURI = refs
        holder.temporaryRefsByURI = temporaryRefs
        holders[key] = holder
        if ownership == .editor {
            restorePendingTemporaryTextIfNeeded(key: key, holder: holder, uri: uri)
        }

        // If the holder never reached `.ready` (init failed), it lingers
        // in the dict so the badge can show `.problem(.dead)` and offer
        // restart. Once the last user-intent ref is released, sweep the
        // dead entry — otherwise repeated open-then-close attempts on a
        // misconfigured server would accumulate stale holders.
        if holder.lifeState == .dead, refs.isEmpty {
            holders.removeValue(forKey: key)
            bumpStateTick()
            return
        }

        let initOk = await holder.ready.value
        guard let cur = holders[key] else { return }
        if !initOk { return }

        // Other tabs still need this file open — nothing to send.
        if (cur.refsByURI[uri] ?? 0) > 0 {
            if ownership == .editor {
                await restoreTemporaryTextIfNeeded(key: key, holder: cur, uri: uri, languageId: languageId)
            }
            return
        }

        // File is fully closed. Send `didClose` if the matching `didOpen`
        // was actually delivered; otherwise the server has nothing to forget.
        if cur.openedURIs.contains(uri) {
            try? await cur.client.didClose(uri: uri)
            if var c = holders[key] {
                c.openedURIs.remove(uri)
                c.versions.removeValue(forKey: uri)
                c.pendingOpenText.removeValue(forKey: uri)
                c.texts.removeValue(forKey: uri)
                c.languagesByURI.removeValue(forKey: uri)
                c.temporaryRefsByURI.removeValue(forKey: uri)
                c.temporaryTextsByURI.removeValue(forKey: uri)
                holders[key] = c
            }
        }

        // Shut down the server if no files remain on it.
        if let c = holders[key], c.refsByURI.isEmpty {
            await c.client.shutdown()
            holders.removeValue(forKey: key)
            bumpStateTick()
        }
    }

    private func restorePendingTemporaryTextIfNeeded(
        key: Key,
        holder: Holder,
        uri: String
    ) {
        guard !holder.openedURIs.contains(uri),
              normalRefCount(forURI: uri, in: holder) == 0,
              (holder.temporaryRefsByURI[uri] ?? 0) > 0,
              let temporaryText = holder.temporaryTextsByURI[uri]
        else {
            return
        }
        guard var current = holders[key],
              current.client === holder.client,
              !current.openedURIs.contains(uri),
              normalRefCount(forURI: uri, in: current) == 0,
              (current.temporaryRefsByURI[uri] ?? 0) > 0
        else {
            return
        }
        current.pendingOpenText[uri] = temporaryText
        holders[key] = current
    }

    private func restoreTemporaryTextIfNeeded(
        key: Key,
        holder: Holder,
        uri: String,
        languageId: String
    ) async {
        guard holder.openedURIs.contains(uri),
              normalRefCount(forURI: uri, in: holder) == 0,
              (holder.temporaryRefsByURI[uri] ?? 0) > 0,
              let temporaryText = holder.temporaryTextsByURI[uri],
              holder.texts[uri] != temporaryText
        else {
            return
        }
        guard var current = holders[key],
              current.client === holder.client,
              current.openedURIs.contains(uri),
              normalRefCount(forURI: uri, in: current) == 0,
              (current.temporaryRefsByURI[uri] ?? 0) > 0
        else {
            return
        }

        let nextVersion = (current.versions[uri] ?? 1) + 1
        let previousText = current.texts[uri]
        current.versions[uri] = nextVersion
        current.texts[uri] = temporaryText
        current.languagesByURI[uri] = languageId
        holders[key] = current
        try? await current.client.didChange(
            uri: uri,
            version: nextVersion,
            text: temporaryText,
            previousText: previousText
        )
    }

    /// Fire-and-forget `textDocument/didSave`. Skipped if the document was
    /// never opened on the server (init still in flight, or a different
    /// holder is in play). Mirrors `didChange`'s readiness semantics.
    func didSave(worktreeRoot: URL, fileURL: URL, languageId: String) async {
        let uri = fileURL.lspURI
        // See `didChange` — find the holder by URI so registry edits made
        // after the open still hit the original server.
        guard let key = holderKey(forURI: uri), let holder = holders[key], holder.openedURIs.contains(uri) else { return }
        let initOk = await holder.ready.value
        guard initOk, let cur = holders[key], cur.openedURIs.contains(uri) else { return }
        try? await cur.client.didSave(uri: uri)
    }

    /// Request `textDocument/formatting` for `fileURL` if a live client is
    /// available and the server advertises formatting support. Returns `nil`
    /// when no client exists, the server doesn't support formatting, or the
    /// request fails. Errors are swallowed so callers can fall back to plain
    /// save.
    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]? {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri), let holder = holders[key], holder.openedURIs.contains(uri) else { return nil }
        let initOk = await holder.ready.value
        guard initOk, let cur = holders[key], cur.openedURIs.contains(uri) else { return nil }
        let supportsFormatting = await cur.client.supportsDocumentFormatting
        guard supportsFormatting else { return nil }
        do {
            let edits = try await cur.client.formatting(uri: uri, options: options)
            return edits
        } catch {
            return nil
        }
    }

    /// Polls until the live client for `(fileURL, language)` is available
    /// (i.e. the buffer's `openDocument` task has completed and a holder
    /// exists), then returns it. Returns `nil` if no client appears within
    /// `timeout` seconds or the task is cancelled.
    func clientWhenReady(forFile fileURL: URL, worktreeRoot: URL, language: String, timeout: TimeInterval = 30) async -> LSPClient? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = openedClient(forFile: fileURL, worktreeRoot: worktreeRoot, language: language) { return c }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Returns the live client serving `fileURL` for `language`, if any.
    /// Resolves the LSP root via the configured `rootMarkers` so a nested
    /// package's client is found correctly even when the caller only knows
    /// the worktree root.
    func client(forFile fileURL: URL, worktreeRoot: URL, language: String) -> LSPClient? {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let holder = holders[key],
              holder.lifeState != .dead else { return nil }
        return holder.client
    }

    /// Coarse holder lifecycle for the file's serving holder, suitable for
    /// the editor status badge. Collapses "no holder yet" and "holder still
    /// initializing" into `.loading` because the user-visible reading is
    /// identical.
    func documentStatus(forFile fileURL: URL, worktreeRoot: URL) -> DocumentStatus {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let holder = holders[key] else {
            return .none
        }
        switch holder.lifeState {
        case .starting: return .loading
        case .ready:
            return holder.openedURIs.contains(uri) ? .ready : .loading
        case .dead: return .dead
        }
    }

    /// Read-only access to the active registry for derivation by views.
    var activeRegistry: LanguageServerRegistry { registry }

    /// Number of open file URIs currently served by the holder serving
    /// `fileURL`. Used by the badge to warn when restarting would affect
    /// multiple tabs. Looks up the holder via the file URI (not the
    /// worktree root) so nested-package holders are matched correctly —
    /// pre-resolving the LSP root from `worktreeRoot` would miss them.
    func openFilesUsing(forFile fileURL: URL, worktreeRoot: URL) -> Int {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot) else { return 0 }
        return holders[key]?.openedURIs.count ?? 0
    }

    /// Returns the client only after the specific file has completed the
    /// initialize + didOpen path. Request/notification features should use
    /// this instead of `client(forFile:)` so they never talk to a server that
    /// is still starting or has not seen the document yet.
    func openedClient(forFile fileURL: URL, worktreeRoot: URL, language: String) -> LSPClient? {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let holder = holders[key],
              holder.openedURIs.contains(uri) else {
            return nil
        }
        return holder.client
    }

    /// Returns `nil` when the file is not currently open on an LSP server.
    /// Returns `false` when it is open but the served text does not contain
    /// `text` at `line`.
    func openedDocumentLineMatches(
        forFile fileURL: URL,
        worktreeRoot: URL,
        line: Int,
        text: String
    ) -> Bool? {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let holder = holders[key],
              holder.openedURIs.contains(uri) else {
            return nil
        }
        guard line >= 0, let servedText = holder.texts[uri] else { return false }
        let lines = servedText.split(separator: "\n", omittingEmptySubsequences: false)
        guard line < lines.count else { return false }
        return String(lines[line]) == text
    }

    /// Tear down the holder currently serving `fileURL` under `worktreeRoot`
    /// and re-open every URI it had open. Holder-scoped (not tab-scoped) so
    /// all tabs sharing the holder benefit from one restart — which matches
    /// the user intuition "restart the Swift server".
    ///
    /// Looks the holder up via `holderKey(forURI:withinWorktreeRoot:)` so a
    /// nested-package holder keyed under a sub-directory of `worktreeRoot`
    /// is found correctly — pre-resolving the LSP root from `worktreeRoot`
    /// would miss nested-package holders.
    ///
    /// No-op when no matching holder exists.
    func restartHolder(forFile fileURL: URL, worktreeRoot: URL, languageId: String) async {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let existing = holders[key] else { return }
        await restartHolder(key: key, existing: existing, language: languageId)
    }

    /// Tear down the holder serving `language` under `rootURL` and re-open
    /// every URI it had open. `rootURL` must be the LSP root the holder is
    /// keyed under; for nested packages, prefer `restartHolder(forFile:worktreeRoot:languageId:)`
    /// which resolves the key via the file URI.
    ///
    /// No-op when no matching holder exists.
    func restartHolder(forLanguage language: String, rootURL: URL) async {
        guard let entry = registry.entry(forLanguage: language) else { return }
        let lspRoot = Self.resolveLSPRoot(fileURL: rootURL, worktreeRoot: rootURL, markers: entry.rootMarkers)
        let key = Key(root: lspRoot.path, command: entry.command, args: entry.args, env: entry.env)
        guard let existing = holders[key] else { return }
        await restartHolder(key: key, existing: existing, language: language)
    }

    private func restartHolder(key: Key, existing: Holder, language: String) async {
        // Mark the holder dead synchronously so the badge transitions through
        // `.dead` and concurrent `openDocument` calls see a dying holder
        // rather than bumping refs on the one we're about to shut down.
        if var h = holders[key], h.client === existing.client {
            h.lifeState = .dead
            holders[key] = h
            bumpStateTick()
        }

        await existing.client.shutdown()

        // Reopen state is sampled AFTER shutdown completes. This @MainActor
        // method is reentrant across the await, so other open/close calls
        // can have mutated `refsByURI`, `texts`, `languagesByURI`, etc. We
        // want to base the reopen on the latest snapshot — otherwise a tab
        // closed during the shutdown await would still get its document
        // reopened, and a tab opened during the await would get dropped.
        //
        // Refcount multiplicity is preserved: a URI held by two tabs has
        // refsByURI[uri] = 2, and `openDocument` increments refs by 1 per
        // call. We call `openDocument` once per reference so the post-
        // restart holder ends with the same refcount.
        //
        // Per-URI languageId is honored on shared servers
        // (typescript-language-server serves typescript / typescriptreact /
        // javascript / javascriptreact under one binary).
        let refsToReopen: [String: Int]
        let temporaryRefsToReopen: [String: Int]
        let temporaryTextsToReopen: [String: String]
        let textsByURI: [String: String]
        let languagesByURI: [String: String]
        if let cur = holders[key], cur.client === existing.client {
            refsToReopen = cur.refsByURI
            temporaryRefsToReopen = cur.temporaryRefsByURI
            temporaryTextsToReopen = cur.temporaryTextsByURI
            textsByURI = cur.texts.merging(cur.pendingOpenText) { current, _ in current }
            languagesByURI = cur.languagesByURI
            holders.removeValue(forKey: key)
            bumpStateTick()
        } else {
            // The holder was already replaced (e.g. by the dead-client
            // detection path in a concurrent `openDocument`). Nothing for
            // us to reopen — the live holder owns its own state.
            return
        }

        let reopenRoot = URL(fileURLWithPath: key.root)
        for (uri, refCount) in refsToReopen {
            guard refCount > 0, let fileURL = URL(string: uri) else { continue }
            let text = textsByURI[uri] ?? ""
            let reopenLanguage = languagesByURI[uri] ?? language
            let temporaryRefCount = temporaryRefsToReopen[uri] ?? 0
            let editorRefCount = max(refCount - temporaryRefCount, 0)
            for _ in 0 ..< editorRefCount {
                _ = await openDocument(worktreeRoot: reopenRoot, fileURL: fileURL, languageId: reopenLanguage, text: text)
            }
            let temporaryText = temporaryTextsToReopen[uri] ?? text
            for _ in 0 ..< temporaryRefCount {
                _ = await openTemporaryDocument(worktreeRoot: reopenRoot, fileURL: fileURL, languageId: reopenLanguage, text: temporaryText)
            }
        }
    }

    /// True when `fileURL` has already been delivered to a live (non-dead)
    /// server via `didOpen`. Lets a re-open path (e.g. after the install
    /// nudge succeeds) skip the call entirely instead of reusing
    /// `openDocument`, which unconditionally bumps `refsByURI` for an
    /// existing holder and would unbalance the eventual `didClose`.
    func isDocumentOpen(fileURL: URL, worktreeRoot: URL) -> Bool {
        let uri = fileURL.lspURI
        guard let key = holderKey(forURI: uri, withinWorktreeRoot: worktreeRoot),
              let holder = holders[key] else { return false }
        return holder.openedURIs.contains(uri) && normalRefCount(forURI: uri, in: holder) > 0
    }

    /// Locates the holder currently tracking `uri` (regardless of which
    /// registry entry version was used to spawn it). Used by close,
    /// didChange, didSave, and `client(forFile:)` so a registry edit
    /// after an open doesn't leak the original server.
    private func holderKey(forURI uri: String) -> Key? {
        for (key, holder) in holders where holder.refsByURI[uri] != nil {
            return key
        }
        return nil
    }

    private func pendingOpenRefs(for ownership: DocumentOwnership) -> [Key: [String: Int]] {
        switch ownership {
        case .editor: return pendingOpenRefs
        case .temporary: return pendingTemporaryOpenRefs
        }
    }

    private func setPendingOpenRefs(_ refs: [Key: [String: Int]], for ownership: DocumentOwnership) {
        switch ownership {
        case .editor: pendingOpenRefs = refs
        case .temporary: pendingTemporaryOpenRefs = refs
        }
    }

    private func addPendingOpenRef(key: Key, uri: String, ownership: DocumentOwnership) {
        var pending = pendingOpenRefs(for: ownership)
        var refs = pending[key] ?? [:]
        refs[uri, default: 0] += 1
        pending[key] = refs
        setPendingOpenRefs(pending, for: ownership)
    }

    private func consumePendingOpenRef(key: Key, uri: String, ownership: DocumentOwnership) -> Bool {
        var pending = pendingOpenRefs(for: ownership)
        guard var refs = pending[key], let count = refs[uri], count > 0 else { return false }
        if count == 1 {
            refs.removeValue(forKey: uri)
        } else {
            refs[uri] = count - 1
        }
        if refs.isEmpty {
            pending.removeValue(forKey: key)
        } else {
            pending[key] = refs
        }
        setPendingOpenRefs(pending, for: ownership)
        return true
    }

    private func consumePendingOpenRef(
        forURI uri: String,
        withinWorktreeRoot worktreeRoot: URL,
        ownership: DocumentOwnership
    ) -> Bool {
        let rootPath = worktreeRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let pending = pendingOpenRefs(for: ownership)
        for key in pending.keys where pending[key]?[uri] != nil {
            if key.root == rootPath || key.root.hasPrefix(rootPrefix) {
                return consumePendingOpenRef(key: key, uri: uri, ownership: ownership)
            }
        }
        return false
    }

    private func holderByUpdatingRefs(
        _ holder: Holder,
        uri: String,
        text: String,
        refs: [String: Int],
        temporaryRefs: [String: Int],
        ownership: DocumentOwnership
    ) -> Holder {
        var pending = holder.pendingOpenText
        var temporaryTexts = holder.temporaryTextsByURI
        if !holder.openedURIs.contains(uri) {
            switch ownership {
            case .editor:
                pending[uri] = text
            case .temporary:
                temporaryTexts[uri] = text
                if normalRefCount(forURI: uri, in: holder) == 0 {
                    pending[uri] = text
                }
            }
        } else if ownership == .temporary {
            temporaryTexts[uri] = text
        }
        return Holder(
            client: holder.client,
            ready: holder.ready,
            refsByURI: refs,
            temporaryRefsByURI: temporaryRefs,
            temporaryTextsByURI: temporaryTexts,
            openedURIs: holder.openedURIs,
            versions: holder.versions,
            pendingOpenText: pending,
            texts: holder.texts,
            languagesByURI: holder.languagesByURI,
            lifeState: holder.lifeState
        )
    }

    private func normalRefCount(forURI uri: String, in holder: Holder) -> Int {
        max((holder.refsByURI[uri] ?? 0) - (holder.temporaryRefsByURI[uri] ?? 0), 0)
    }

    /// Worktree-scoped variant: returns a holder for `uri` only if its
    /// `Key.root` falls inside `worktreeRoot`. Used as the last fallback in
    /// external open/close so a tab in worktree B never matches a holder in
    /// worktree A that happens to serve the same SDK file.
    private func holderKey(forURI uri: String, withinWorktreeRoot worktreeRoot: URL) -> Key? {
        let rootPath = worktreeRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for (key, holder) in holders where holder.refsByURI[uri] != nil {
            if key.root == rootPath || key.root.hasPrefix(rootPrefix) {
                return key
            }
        }
        return nil
    }

    /// Find an existing holder serving any file inside `worktreeRoot` for
    /// `language`. Used by external-document open/close where we don't have
    /// an in-worktree file URI on hand but know the originating worktree.
    ///
    /// Unlike the old `holderKey(forWorktreeRoot:language:)` helper, this
    /// scans existing holders instead of recomputing the key from scratch.
    /// That matters for workspaces with nested packages: the running holder
    /// was keyed against the nested package directory, not the worktree root,
    /// so a recomputed lookup would miss it.
    private func holderKeyForExternal(worktreeRoot: URL, language: String) -> Key? {
        guard let entry = registry.entry(forLanguage: language) else { return nil }
        let worktreePath = worktreeRoot.path
        let pathPrefix = worktreePath.hasSuffix("/") ? worktreePath : worktreePath + "/"
        for (key, holder) in holders {
            guard key.command == entry.command,
                  key.args == entry.args,
                  key.env == entry.env else { continue }
            // The holder's lspRoot may be the worktree itself or a nested
            // package directory inside it. Either way, its path must start
            // with the worktree path.
            if key.root == worktreePath || key.root.hasPrefix(pathPrefix) {
                return key
            }
            // Fallback: if the holder has any open URI inside the worktree,
            // it's serving this workspace.
            for uri in holder.refsByURI.keys {
                if let url = URL(string: uri),
                   url.path.hasPrefix(pathPrefix) {
                    return key
                }
            }
        }
        return nil
    }

    /// Notify the running LSP client for `originatingWorktreeRoot`/`language`
    /// that a read-only out-of-worktree file is logically open. Issues
    /// `textDocument/didOpen` the first time a given URI is registered and
    /// increments a reference count for subsequent calls with the same URI.
    ///
    /// `originatingFileURL` is the in-worktree file the user was viewing when
    /// they navigated to this external document (e.g. via ⌘-click). When
    /// provided, the holder is looked up via the existing URI-keyed helper
    /// (`holderKey(forURI:)`) so nested-package layouts with multiple LSP
    /// servers resolve to the correct server. Falls back to the prefix-scan
    /// approach when nil or when the originating file's URI isn't tracked yet
    /// (e.g. app restart with persisted external tabs).
    ///
    /// Returns `true` when a holder was found and `didOpen` was sent (or the
    /// URI was already open with a positive refcount). Returns `false` when no
    /// holder was available — the call silently no-ops in that case and the
    /// caller can retry later.
    @discardableResult
    func openExternalDocument(
        absoluteURL: URL,
        originatingWorktreeRoot: URL,
        originatingFileURL: URL? = nil,
        language: String,
        contents: String
    ) async -> Bool {
        let uri = absoluteURL.lspURI
        let key: Key?
        if let originatingFileURL,
           let preciseKey = holderKey(forURI: originatingFileURL.lspURI) {
            key = preciseKey
        } else {
            // Fall back to prefix-scan; also try scanning by the external
            // URI itself. Use worktree-scoped lookup as the last fallback
            // to avoid matching a holder in a different worktree that
            // happens to serve the same SDK file.
            key = holderKeyForExternal(worktreeRoot: originatingWorktreeRoot, language: language) ?? holderKey(forURI: uri, withinWorktreeRoot: originatingWorktreeRoot)
        }
        guard let key, var holder = holders[key] else { return false }

        // Skip dead holders so an external-tab reopen/retry loop doesn't
        // accumulate refs on a server that's never going to answer. The
        // caller treats `false` as "retry later"; the in-worktree
        // `openDocument` path will respawn a fresh holder when a real tab
        // opens, and the badge can offer Restart in the meantime.
        guard holder.lifeState != .dead else { return false }

        // Bump refcount and record pending text in case the server is still
        // initializing — the same approach used by openDocument for in-worktree
        // files.
        var refs = holder.refsByURI
        refs[uri, default: 0] += 1
        var pending = holder.pendingOpenText
        if !holder.openedURIs.contains(uri) { pending[uri] = contents }
        holder.refsByURI = refs
        holder.pendingOpenText = pending
        holders[key] = holder

        let initOk = await holder.ready.value
        guard initOk, let cur = holders[key], cur.client === holder.client,
              (cur.refsByURI[uri] ?? 0) > 0 else { return false }

        if !cur.openedURIs.contains(uri) {
            let openText = cur.pendingOpenText[uri] ?? contents
            if var h = holders[key] {
                h.openedURIs.insert(uri)
                h.versions[uri] = 1
                h.pendingOpenText.removeValue(forKey: uri)
                h.texts[uri] = openText
                // Record the languageId so `restartHolder` can reopen
                // this URI under the right language on shared servers
                // (typescript-language-server, etc).
                h.languagesByURI[uri] = language
                holders[key] = h
                // Match in-worktree `openDocument`: bump the tick so the
                // badge transitions from `.loading` to `.ready` (and the
                // restart-impact count refreshes) without waiting for an
                // unrelated UI change.
                bumpStateTick()
            }
            try? await cur.client.didOpen(
                uri: uri,
                languageId: language,
                version: 1,
                text: openText
            )
        }
        return true
    }

    /// Notify the running LSP client that a previously opened external
    /// (out-of-worktree) document is no longer needed. Decrements the
    /// reference count incremented by `openExternalDocument`; when it reaches
    /// zero, issues `textDocument/didClose`.
    ///
    /// `originatingFileURL` mirrors the parameter on `openExternalDocument`:
    /// when provided, the holder is found via URI lookup for precision in
    /// nested-package layouts. Falls back to the prefix-scan approach when
    /// nil or not yet tracked.
    ///
    /// Silently no-ops if no LSP client is running for the given worktree and
    /// language, or if the URI was never opened.
    func closeExternalDocument(
        absoluteURL: URL,
        originatingWorktreeRoot: URL,
        originatingFileURL: URL? = nil,
        language: String
    ) async {
        let uri = absoluteURL.lspURI
        let key: Key?
        if let originatingFileURL,
           let preciseKey = holderKey(forURI: originatingFileURL.lspURI) {
            key = preciseKey
        } else {
            // Scan the external URI itself first (scoped to the worktree) to
            // ensure we decrement the correct holder. Only fall back to the
            // language-by-worktree scan if the URI isn't found in any holder's
            // refsByURI — with multiple nested LSP holders for the same language,
            // the prefix-scan could pick an arbitrary holder that doesn't actually
            // have this URI registered, leaving the ref count imbalanced.
            key = holderKey(forURI: uri, withinWorktreeRoot: originatingWorktreeRoot) ?? holderKeyForExternal(worktreeRoot: originatingWorktreeRoot, language: language)
        }
        guard let key,
              var holder = holders[key],
              (holder.refsByURI[uri] ?? 0) > 0 else { return }

        // Decrement the refcount synchronously before awaiting.
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
        guard initOk, let cur = holders[key] else { return }

        // Another opener still has this URI open — nothing to send.
        if (cur.refsByURI[uri] ?? 0) > 0 { return }

        // Send didClose only if didOpen was actually delivered.
        if cur.openedURIs.contains(uri) {
            try? await cur.client.didClose(uri: uri)
            if var c = holders[key] {
                c.openedURIs.remove(uri)
                c.versions.removeValue(forKey: uri)
                c.pendingOpenText.removeValue(forKey: uri)
                c.texts.removeValue(forKey: uri)
                c.languagesByURI.removeValue(forKey: uri)
                holders[key] = c
            }
        }
        // Shut down the server only when no refs remain. External documents
        // attach to a running server that may also serve in-worktree tabs;
        // skip teardown when in-worktree refs are still present. If the
        // external doc was the last reference, the holder must be cleaned up
        // to avoid leaking the LSP process until app exit.
        if let c = holders[key], c.refsByURI.isEmpty {
            await c.client.shutdown()
            holders.removeValue(forKey: key)
            bumpStateTick()
        }
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
        let environment: [String: String]
    }

    /// Resolves the spawn command for `entry`. Bare commands (no `/`) are
    /// resolved against PATH and the Swift xcrun fallback so the badge and
    /// launch paths stay consistent. When `xcrun --find sourcekit-lsp`
    /// returns an absolute path, we use it directly instead of wrapping
    /// with `/usr/bin/env` — that ensures `sourcekit-lsp` launches even
    /// when it lives inside Xcode.app and isn't on PATH.
    private static func resolveSpawn(
        command: String,
        args: [String],
        env: [String: String],
        language: String,
        availability: LanguageServerAvailability,
        remoteHost: String? = nil,
        rootPath: String? = nil
    ) -> Spawn {
        if let remoteHost, let rootPath {
            let invocation = RemoteLSPLauncher.invocation(
                host: remoteHost,
                rootPath: rootPath,
                command: command,
                args: args,
                env: env
            )
            return Spawn(
                executable: URL(fileURLWithPath: invocation.executable),
                arguments: invocation.args,
                environment: [:]
            )
        }
        let probe = LanguageServerConfig(
            language: language, extensions: [], command: command, args: args,
            env: env, rootMarkers: [], enabled: true
        )
        if command.contains("/") {
            return Spawn(
                executable: URL(fileURLWithPath: command),
                arguments: args,
                environment: availability.launchEnvironment(for: probe)
            )
        }
        if let spawnArgs = availability.spawnArguments(for: probe) {
            return Spawn(
                executable: URL(fileURLWithPath: spawnArgs.executable),
                arguments: spawnArgs.arguments,
                environment: availability.launchEnvironment(for: probe)
            )
        }
        return Spawn(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [command] + args,
            environment: availability.launchEnvironment(for: probe)
        )
    }

    // MARK: - Root resolution

    /// Walks up from `fileURL`'s parent toward `worktreeRoot`, returning the
    /// nearest ancestor directory that contains any of the `markers`. This
    /// lets sourcekit-lsp (or any other server with `rootMarkers` set in
    /// `LanguageServerRegistry`) initialize at the proper package/project
    /// root for files in nested packages — `Package.swift`, `*.xcodeproj`,
    /// `.git`, etc. Falls back to `worktreeRoot` when no marker is found.
    /// Patterns may contain `*` for simple globs.
    static func resolveLSPRoot(fileURL: URL, worktreeRoot: URL, markers: [String]) -> URL {
        guard !markers.isEmpty else { return worktreeRoot }
        let fm = FileManager.default
        let worktreePath = worktreeRoot.standardizedFileURL.path
        var dir = fileURL.deletingLastPathComponent().standardizedFileURL
        // Bound the climb to the worktree — never escape upward.
        while dir.path.hasPrefix(worktreePath) {
            if directory(dir, contains: markers, fm: fm) {
                return dir
            }
            if dir.path == worktreePath { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return worktreeRoot
    }

    static func remoteLSPRootProbeCommand(fileURL: URL, worktreeRoot: URL, markers: [String]) -> String {
        let markerAssignments = markers.enumerated().map { index, marker in
            "m\(index)=\(SSHCommand.shellQuote(marker))"
        }.joined(separator: "; ")
        let markerChecks = markers.enumerated().map { index, marker -> String in
            let markerVariable = "\"$m\(index)\""
            if marker.contains("*") {
                return "if find \"$dir\" -maxdepth 1 -name \(markerVariable) -print -quit | grep -q .; then printf '%s\\n' \"$dir\"; exit 0; fi"
            }
            return "if [ -e \"$dir/$m\(index)\" ]; then printf '%s\\n' \"$dir\"; exit 0; fi"
        }.joined(separator: "; ")
        let file = SSHCommand.shellQuote(fileURL.path)
        let root = SSHCommand.shellQuote(worktreeRoot.path)
        return """
        file=\(file); root=\(root); \(markerAssignments); dir=$(dirname "$file"); case "$dir" in "$root"|"$root"/*) ;; *) printf '%s\\n' "$root"; exit 0;; esac; while :; do \(markerChecks); [ "$dir" = "$root" ] && break; parent=$(dirname "$dir"); [ "$parent" = "$dir" ] && break; dir="$parent"; done; printf '%s\\n' "$root"
        """
    }

    static func resolveRemoteLSPRoot(fileURL: URL, worktreeRoot: URL, markers: [String], host: String) async -> URL {
        guard !markers.isEmpty else { return worktreeRoot }
        do {
            let result = try await RemoteExec.run(
                host: host,
                cwd: nil,
                command: remoteLSPRootProbeCommand(fileURL: fileURL, worktreeRoot: worktreeRoot, markers: markers)
            )
            guard result.exitCode == 0 else { return worktreeRoot }
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return worktreeRoot }
            return URL(fileURLWithPath: path)
        } catch {
            return worktreeRoot
        }
    }

    private static func directory(_ dir: URL, contains markers: [String], fm: FileManager) -> Bool {
        var entries: [String]?
        for marker in markers {
            if marker.contains("*") {
                if entries == nil { entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] }
                if let entries, entries.contains(where: { glob(marker, $0) }) { return true }
            } else {
                if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) { return true }
            }
        }
        return false
    }

    /// Minimal `*` glob — covers the realistic rootMarker shapes
    /// (`*.xcodeproj`, `*.json`, `Package.*`) without pulling in regex or
    /// `fnmatch(3)`. Multiple `*` are supported; `?` and character classes
    /// are not.
    private static func glob(_ pattern: String, _ name: String) -> Bool {
        if !pattern.contains("*") { return pattern == name }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var idx = name.startIndex
        if let first = parts.first, !first.isEmpty {
            guard name.hasPrefix(first) else { return false }
            idx = name.index(idx, offsetBy: first.count)
        }
        if let last = parts.last, parts.count > 1, !last.isEmpty {
            guard name.hasSuffix(last) else { return false }
        }
        for chunk in parts.dropFirst().dropLast() where !chunk.isEmpty {
            guard let r = name.range(of: chunk, range: idx..<name.endIndex) else { return false }
            idx = r.upperBound
        }
        return true
    }
}
