import AppKit
import Foundation
import Observation

struct RemoteConflictCheckCoalescer {
    private var isChecking = false
    private var hasPendingCheck = false

    mutating func beginOrMarkPending() -> Bool {
        guard !isChecking else {
            hasPendingCheck = true
            return false
        }
        isChecking = true
        return true
    }

    mutating func finishCheck() -> Bool {
        guard hasPendingCheck else {
            isChecking = false
            return false
        }
        hasPendingCheck = false
        return true
    }
}

struct RemoteHelperFileWatchMatcher {
    private let targetPath: String
    private let targetRelativePath: String?

    init(targetURL: URL, watchedRootURL: URL) {
        targetPath = Self.normalizedPath(targetURL.path)
        targetRelativePath = Self.relativePath(of: targetURL.path, under: watchedRootURL.path)
    }

    func matches(event: RemoteHelperWatchEvent) -> Bool {
        event.paths.contains { eventPath in
            let normalizedEventPath = Self.normalizedPath(eventPath)
            if normalizedEventPath == targetPath { return true }
            guard
                let targetRelativePath,
                let eventRelativePath = Self.relativePath(of: normalizedEventPath, under: event.root)
            else {
                return false
            }
            return eventRelativePath == targetRelativePath
        }
    }

    private static func relativePath(of path: String, under root: String) -> String? {
        let path = normalizedPath(path)
        let root = normalizedPath(root)
        guard !root.isEmpty, path != root else { return nil }
        let prefix = root == "/" ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let isAbsolute = path.hasPrefix("/")
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(String(component))
                }
            default:
                components.append(String(component))
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined
    }
}

/// Editor buffer for one open worktree file. Owns the live `NSTextStorage` displayed by
/// `CodeTextView`, plus the original-on-disk snapshot used for dirty
/// detection, save normalization, and conflict resolution.
///
/// Buffers are stored in `TabsManager` by worktree-relative path so they
/// outlive the SwiftUI view (which can be torn down and rebuilt). All
/// state mutations happen on the main actor; storage delegate callbacks,
/// LSP responses, and file-watch events are routed through `MainActor`
/// before touching `self`.
@Observable
@MainActor
final class EditorBuffer {
    enum SaveError: LocalizedError {
        case loadPending
        case remoteSaveRequiresAwait
        case remoteSaveConflict

        var errorDescription: String? {
            switch self {
            case .loadPending:
                "File is still loading. Try saving again after it finishes."
            case .remoteSaveRequiresAwait:
                "Remote saves must finish before this action can continue."
            case .remoteSaveConflict:
                "The remote file changed before the save completed."
            }
        }
    }

    let worktreeRoot: URL
    private(set) var relativePath: String

    /// `true` when this buffer represents a file outside the worktree (e.g.
    /// a dependency or system header opened via cmd-click). External buffers
    /// are read-only, never emit `didChange` to LSP, and never write back to
    /// disk — but they still reload when the file changes on disk.
    let isExternal: Bool

    /// External buffers are read-only by default (SDK files opened via
    /// ⌘-click). Run-script editing opts in to editing + saving; the save
    /// path already targets the right file because external buffers use
    /// parent-dir/filename as their sentinel worktreeRoot/relativePath.
    let externalEditable: Bool

    /// The live AppKit text storage displayed by the text view. The
    /// reference is stable for the lifetime of the buffer; tearing down
    /// the view detaches it without releasing it.
    let storage: NSTextStorage

    private(set) var originalText: String = ""
    private(set) var originalMtime: Date = .distantPast
    private(set) var permissions: mode_t = 0o644
    private(set) var lineEnding: LineEnding = .lf
    private(set) var readOnly: Bool = false

    enum Conflict: Equatable {
        case changedOnDisk
        case deletedOnDisk
    }

    private(set) var conflict: Conflict?

    var lastSaveError: String?

    /// The last load result kind, observable by SwiftUI. Set by
    /// `applyLoadResult`. The view uses this to render the binary
    /// placeholder overlay when the file isn't valid UTF-8.
    private(set) var loadKind: LoadKind = .loaded

    private(set) var editGeneration: Int = 0

    @ObservationIgnored
    private var editObservers: [UUID: (EditorTextEdit?) -> Void] = [:]
    @ObservationIgnored
    private var storageDelegate: BufferStorageDelegate = .init { _ in }
    private enum LoadState {
        struct Pending {
            let generation: Int
            let hasPendingSnapshot: Bool
            var userEdits: [EditorTextEdit] = []
            var preloadText = ""
            var queuedReload: Bool = false
            var suppressEditTracking: Bool = false

            var hasUserEdits: Bool { !userEdits.isEmpty }
        }

        case loaded(preloadUserEdits: Bool)
        case loading(Pending)
        case cancelled

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }
    @ObservationIgnored
    private var loadState: LoadState = .loaded(preloadUserEdits: false)
    @ObservationIgnored
    private var programmaticEditDepth = 0
    @ObservationIgnored
    private var watcherSource: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var watcherFD: Int32 = -1
    @ObservationIgnored
    private let remoteHost: String?
    var isRemote: Bool { remoteHost != nil }
    @ObservationIgnored
    private var remotePollTask: Task<Void, Never>?
    @ObservationIgnored
    private var remoteHelperSession: RemoteHelperWatchSession?
    @ObservationIgnored
    private var remoteConflictChecks = RemoteConflictCheckCoalescer()
    @ObservationIgnored
    private static let remoteConflictPollNanos: UInt64 = 15 * 1_000_000_000
    @ObservationIgnored
    private static let remoteHelperSafetyNetNanos: UInt64 = 5 * 60 * 1_000_000_000
    @ObservationIgnored
    private var remoteLoadGeneration = 0
    @ObservationIgnored
    private var remoteSaveGeneration = 0
    @ObservationIgnored
    private var remoteSaveInFlight = false
    @ObservationIgnored
    private var remoteOverwriteAfterConflict = false
    @ObservationIgnored
    private var restoredRemoteSnapshot = false
    @ObservationIgnored
    private static let watchQueue = DispatchQueue(label: "alas.editor.buffer.watch", qos: .utility)
    @ObservationIgnored
    private var moveLookupTask: Task<MovedFileLookupResult?, Never>?
    @ObservationIgnored
    private var moveLookupGeneration = 0
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var nextLoadGeneration = 0
    @ObservationIgnored
    nonisolated(unsafe) static var loadGateForTesting: (@Sendable () async -> Void)?
    @ObservationIgnored
    nonisolated(unsafe) static var loadResultForTesting: (@Sendable (URL) async -> String?)?
    /// Test hook that bypasses the real SSH read and containment checks.
    /// The closure receives `(host, path)` and returns the read result.
    @ObservationIgnored
    nonisolated(unsafe) static var remoteReadResultForTesting: (@Sendable (String, String) async throws -> RemoteReadResult)?
    @ObservationIgnored
    private var originalFileIdentifier: AnyObject?
    @ObservationIgnored
    private var originalVolumeIdentifier: AnyObject?
    @ObservationIgnored
    private let store: EditorBufferStore?
    @ObservationIgnored
    private let worktreeId: String?
    @ObservationIgnored
    private var tabId: String?
    @ObservationIgnored
    private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored
    private let lsp: WorkspaceLSPManager?
    @ObservationIgnored
    private(set) var language: String?

    /// Language identifier the buffer last instructed the LSP server to
    /// open this document under. Tracks what the *server* knows, which
    /// can lag `effectiveLanguage` across the async close/open hop on
    /// override change. Initialized when the buffer's init-time `didOpen`
    /// is scheduled; updated synchronously when an override transition
    /// fires. Used by every LSP path (didClose, didSave, close()) so
    /// notifications always reference the holder that's actually open.
    @ObservationIgnored
    private var openedLanguage: String?

    /// Serializes the async close+open hop fired by `applyEffectiveLanguageToLSP`
    /// across rapid override changes. Without this, a chain like
    /// swift→typescript→python could land its tasks out of order — an older
    /// task reopens the stale language *after* the newer one, leaving the
    /// document attached to the wrong holder and unbalancing future close/ref
    /// bookkeeping. Each new override change awaits the previous chain
    /// before issuing its own close+open.
    @ObservationIgnored
    private var languageReopenTask: Task<Void, Never>?
    @ObservationIgnored
    private var lspOpenTask: Task<Void, Never>?
    @ObservationIgnored
    private var lspOpenGeneration = 0

    /// Per-tab, per-session override of the inferred language. Setting this
    /// drives the buffer to close the document on the previous language
    /// holder and reopen it under the new effective language. Cleared
    /// automatically when the buffer is torn down at tab close.
    var languageOverride: String? {
        didSet {
            guard languageOverride != oldValue else { return }
            applyEffectiveLanguageToLSP()
        }
    }

    /// Language used for LSP routing, syntax highlighting, and the status
    /// badge. `languageOverride` (set by the badge popover) wins; otherwise
    /// the inferred `language` from the file extension is used.
    var effectiveLanguage: String? { languageOverride ?? language }

    #if DEBUG
    /// Test-only setter so unit tests can simulate a buffer whose
    /// inferred language has already been computed.
    func setLanguageForTest(_ value: String?) { language = value }
    #endif

    @ObservationIgnored
    var shouldFollowPathChange: ((String, String) -> Bool)?
    @ObservationIgnored
    var onPathChanged: ((String, String) -> Void)?
    @ObservationIgnored
    var onRestoredPathChanged: ((String, String) -> Void)?
    @ObservationIgnored
    var onInitialLoadFinished: (() -> Void)?
    @ObservationIgnored
    var onSnapshotRequested: (() -> Void)?
    @ObservationIgnored
    var onDiscardSnapshotsRequested: (() -> Void)?
    @ObservationIgnored
    private var pendingRestoredPathChange: (oldPath: String, newPath: String)?
    var persistenceTabId: String? { tabId }
    @ObservationIgnored
    private(set) var initialLoadFinished = false

    enum SaveDisposition: Equatable {
        case clean
        case ready
        case blockedByLoad
    }

    struct EditObserverToken { fileprivate let id: UUID }

    /// `true` while the in-memory text differs from the bytes last read
    /// from / written to disk. Computed from `storage.string` against
    /// `originalText` (cheap for files under ~1 MB).
    var dirty: Bool {
        guard !readOnly else { return false }
        return storage.string != originalText
    }

    /// Convenience initializer for callers that do not need hot-exit support
    /// (tests from Tasks 3-6, and any non-persisted buffer).
    convenience init(worktreeRoot: URL, relativePath: String) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: nil, worktreeId: nil, tabId: nil, restoreEnabled: false, lsp: nil)
    }

    /// Production initializer that opts into hot-exit (no LSP). The `store`
    /// is consulted at init time for any persisted snapshot.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, checkConflictOnRestore: Bool = false) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: nil, checkConflictOnRestore: checkConflictOnRestore)
    }

    /// Synchronous load variant for non-UI save materialization. Normal editor
    /// opens use the async load path to avoid blocking the main thread.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, loadSynchronously: Bool) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: nil, loadSynchronously: loadSynchronously)
    }

    /// Production initializer that opts into hot-exit and opens an LSP
    /// document. The buffer owns the LSP open/close lifecycle for this file.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, lsp: WorkspaceLSPManager, checkConflictOnRestore: Bool = false) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: lsp, checkConflictOnRestore: checkConflictOnRestore)
    }

    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, lsp: WorkspaceLSPManager, loadSynchronously: Bool) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: lsp, loadSynchronously: loadSynchronously)
    }

    /// External-mode init: loads `absoluteURL` synchronously, marks the buffer
    /// read-only, and skips all save/didChange/file-watcher write paths. The
    /// buffer still re-loads contents when the file changes on disk (passive
    /// reload only — it never writes back). Uses sentinel worktreeRoot/
    /// relativePath values (directory + filename) so the rest of the buffer
    /// machinery works without optional-unwrap proliferation (option B).
    convenience init(
        externalAbsoluteURL: URL,
        editable: Bool = false,
        store: EditorBufferStore? = nil,
        worktreeId: String? = nil,
        tabId: String? = nil
    ) {
        let worktreeRoot = externalAbsoluteURL.deletingLastPathComponent()
        let relativePath = externalAbsoluteURL.lastPathComponent
        self.init(
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            isExternal: true,
            store: editable ? store : nil,
            worktreeId: editable ? worktreeId : nil,
            tabId: editable ? tabId : nil,
            restoreEnabled: editable,
            lsp: nil,
            externalEditable: editable
        )
    }

    private init(worktreeRoot: URL, relativePath: String, isExternal: Bool, store: EditorBufferStore?, worktreeId: String?, tabId: String?, restoreEnabled: Bool, lsp: WorkspaceLSPManager?, loadSynchronously: Bool = false, checkConflictOnRestore: Bool = false, externalEditable: Bool = false) {
        self.worktreeRoot = worktreeRoot
        self.relativePath = relativePath
        self.isExternal = isExternal
        self.externalEditable = externalEditable
        self.remoteHost = RemoteHostRegistry.shared.host(
            forPath: worktreeRoot.appendingPathComponent(relativePath).path
        )
        self.storage = NSTextStorage()
        self.store = store
        self.worktreeId = worktreeId
        self.tabId = tabId
        self.lsp = lsp
        self.language = lsp?.language(forFileExtension: (relativePath as NSString).pathExtension)
        let delegate = BufferStorageDelegate { [weak self] edit in self?.handleEdit(edit: edit) }
        self.storageDelegate = delegate
        self.storage.delegate = delegate
        let snapshot: EditorBufferStore.Snapshot?
        if restoreEnabled, let store, let worktreeId, let tabId {
            snapshot = (try? store.read(worktreeId: worktreeId, tabId: tabId)) ?? nil
        } else {
            snapshot = nil
        }
        let finishLoad: @MainActor (LoadState.Pending?) -> Void = { [weak self] pending in
            self?.finishInitialLoad(
                isExternal: isExternal,
                snapshot: snapshot,
                pendingUserEdits: pending?.userEdits ?? [],
                preloadText: pending?.preloadText ?? "",
                lsp: lsp,
                checkConflictOnRestore: checkConflictOnRestore
            )
        }
        if isExternal || loadSynchronously {
            loadFromDiskSync()
            finishLoad(nil)
        } else {
            loadFromDisk(
                preservePendingEdits: true,
                notifyAfterLoad: false,
                hasPendingSnapshot: snapshot != nil,
                completion: finishLoad
            )
        }
    }

    private func finishInitialLoad(
        isExternal: Bool,
        snapshot: EditorBufferStore.Snapshot?,
        pendingUserEdits: [EditorTextEdit],
        preloadText: String,
        lsp: WorkspaceLSPManager?,
        checkConflictOnRestore: Bool = false
    ) {
        if case .cancelled = loadState { return }
        var restoredContent = false
        if (!isExternal || externalEditable),
           let snap = snapshot {
            applySnapshot(snap)
            restoredContent = true
            if onRestoredPathChanged != nil,
               let restoredPathChange = consumeRestoredPathChange() {
                onRestoredPathChanged?(restoredPathChange.oldPath, restoredPathChange.newPath)
                if case .cancelled = loadState { return }
            }
        }
        if !pendingUserEdits.isEmpty {
            replayPendingUserEdits(pendingUserEdits, fallbackText: preloadText)
            restoredContent = true
            conflict = .changedOnDisk
        }
        // If we restored a hot-exit snapshot or replayed pending user edits
        // *and* the on-disk load failed (binary/unreadable/missing), the
        // buffer now shows editable text content that the user authored.
        // Don't leave `loadKind` as `.notUTF8`/`.missing` (or `EditorTabView`
        // swaps to the binary placeholder and hides the draft), and clear
        // `readOnly` so the draft is editable and saveable. Skip this for
        // successful loads: symlinks and external files are legitimately
        // read-only even when the user typed before the load completed.
        if restoredContent, loadKind != .loaded {
            loadKind = .loaded
            readOnly = false
        }
        if checkConflictOnRestore {
            checkForConflictOnRestore()
        }
        onEdit { [weak self] in self?.scheduleSnapshot() }
        // Notify any already-attached coordinator that content has arrived
        // so it can re-apply base style (font/color) to the freshly loaded
        // storage. Without this, bindBuffer's applyBaseStyle ran against
        // empty storage and the loadFromDisk setAttributedString wiped
        // everything, leaving the text view unstyled.
        handleEdit(edit: nil)
        initialLoadFinished = true
        openLSPDocumentIfReady()
        onInitialLoadFinished?()
    }

    /// Re-fire `didOpen` for this buffer's current text. Used after a
    /// language server becomes available (e.g. installed via the editor
    /// nudge or Settings) so an already-open buffer can pick it up without
    /// the user closing and reopening the tab. No-op for external buffers
    /// (those use a different open path), for buffers with no resolved
    /// language, and for buffers whose document is already attached to a
    /// live server — `openDocument` increments `refsByURI` before checking
    /// `openedURIs`, so blindly re-calling it for an already-attached
    /// document would leave a dangling ref the next `didClose` couldn't
    /// balance.
    func reopenLSPDocument() {
        openLSPDocumentIfReady()
    }

    private func openLSPDocumentIfReady() {
        guard initialLoadFinished,
              !isExternal,
              remoteHost == nil,
              openedLanguage == nil,
              lspOpenTask == nil,
              let lsp,
              let effective = effectiveLanguage else { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        guard !lsp.isDocumentOpen(fileURL: url, worktreeRoot: worktreeRoot) else { return }
        let text = storage.string
        lspOpenGeneration &+= 1
        let generation = lspOpenGeneration
        lspOpenTask = Task { [weak self] in
            let opened = await lsp.openDocument(
                worktreeRoot: worktreeRoot,
                fileURL: url,
                languageId: effective,
                text: text
            ) != nil
            guard let self else {
                if opened {
                    await lsp.closeDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: effective)
                }
                return
            }
            guard !Task.isCancelled,
                  self.lspOpenGeneration == generation,
                  self.initialLoadFinished,
                  self.effectiveLanguage == effective else {
                if opened {
                    await lsp.closeDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: effective)
                }
                return
            }
            self.lspOpenTask = nil
            if opened {
                self.openedLanguage = effective
            }
        }
    }

    private func cancelPendingLSPOpen() {
        lspOpenGeneration &+= 1
        lspOpenTask?.cancel()
        lspOpenTask = nil
    }

    func reopenLSPDocument(afterRegistering language: String, forFileExtensions extensions: Set<String>) {
        guard !isExternal, let lsp else { return }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return }
        guard lsp.language(forFileExtension: ext) == language else { return }
        self.language = language
        reopenLSPDocument()
    }

    @discardableResult
    func onEdit(_ block: @escaping () -> Void) -> EditObserverToken {
        onTextEdit { _ in block() }
    }

    @discardableResult
    func onTextEdit(_ block: @escaping (EditorTextEdit?) -> Void) -> EditObserverToken {
        let id = UUID()
        editObservers[id] = block
        return EditObserverToken(id: id)
    }

    func removeOnEdit(_ token: EditObserverToken) {
        editObservers.removeValue(forKey: token.id)
    }

    func adoptPersistenceTabId(_ tabId: String) {
        guard self.tabId != tabId else { return }
        self.tabId = tabId
        if dirty { snapshotNow() }
    }

    func consumeRestoredPathChange() -> (oldPath: String, newPath: String)? {
        guard let change = pendingRestoredPathChange else { return nil }
        pendingRestoredPathChange = nil
        return change
    }

    private var isLoading: Bool { loadState.isLoading }

    var saveDisposition: SaveDisposition {
        switch loadState {
        case .loading(let pending):
            return pending.hasUserEdits || pending.hasPendingSnapshot ? .blockedByLoad : .clean
        case .loaded:
            return dirty ? .ready : .clean
        case .cancelled:
            return .clean
        }
    }

    private func beginAsyncLoad(hasPendingSnapshot: Bool) -> Int {
        loadTask?.cancel()
        nextLoadGeneration &+= 1
        let generation = nextLoadGeneration
        loadState = .loading(.init(generation: generation, hasPendingSnapshot: hasPendingSnapshot))
        return generation
    }

    private func acceptLoadCompletion(generation: Int) -> LoadState.Pending? {
        guard case .loading(let pending) = loadState,
              pending.generation == generation else { return nil }
        loadTask = nil
        loadState = .loaded(preloadUserEdits: pending.hasUserEdits)
        return pending
    }

    private func cancelPendingLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadState = .cancelled
    }

    private func markUserEditDuringLoadIfNeeded(_ edit: EditorTextEdit) -> Bool {
        guard case .loading(var pending) = loadState else { return false }
        guard !pending.suppressEditTracking else { return true }
        pending.userEdits.append(edit)
        pending.preloadText = storage.string
        loadState = .loading(pending)
        return true
    }

    private func queueReloadDuringLoadIfNeeded() -> Bool {
        guard case .loading(var pending) = loadState else { return false }
        pending.queuedReload = true
        loadState = .loading(pending)
        return true
    }

    private func withLoadEditTrackingSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        programmaticEditDepth += 1
        guard case .loading(var pending) = loadState else {
            defer { programmaticEditDepth -= 1 }
            return try body()
        }
        pending.suppressEditTracking = true
        loadState = .loading(pending)
        defer {
            programmaticEditDepth -= 1
            if case .loading(var current) = loadState,
               current.generation == pending.generation {
                current.suppressEditTracking = false
                loadState = .loading(current)
            }
        }
        return try body()
    }

    private func handleEdit(edit: EditorTextEdit?) {
        guard programmaticEditDepth == 0 else { return }
        if let edit, markUserEditDuringLoadIfNeeded(edit) {
            return
        }
        // Read-only external buffers suppress all observer notifications so
        // didChange is never propagated to LSP or snapshot scheduling. The
        // explicitly editable external buffers used by run scripts still need
        // this invalidation path for their dirty indicator and Save All state.
        guard !isExternal || externalEditable else { return }
        editGeneration &+= 1
        let snapshot = Array(editObservers.values)
        for block in snapshot { block(edit) }
    }

    func revert() {
        if let remoteHost {
            beginRemoteLoad(host: remoteHost, replacingDirty: true)
            discardSnapshot()
            handleEdit(edit: nil)
            return
        }
        loadFromDisk(preservePendingEdits: false) { [weak self] _ in
            self?.discardSnapshot()
            self?.handleEdit(edit: nil)
        }
    }

    func startWatching() {
        stopWatching()
        if let remoteHost {
            startRemoteHelperWatching(host: remoteHost)
            startRemoteConflictPolling()
            return
        }
        let path = worktreeRoot.appendingPathComponent(relativePath).path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: Self.watchQueue
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleWatcherEvent() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcherSource = src
        watcherFD = fd
    }

    func startWatchingIfNeeded() {
        if remoteHost != nil {
            guard remoteHelperSession == nil else { return }
        } else {
            guard watcherSource == nil else { return }
        }
        startWatching()
    }

    func stopWatching() {
        remotePollTask?.cancel()
        remotePollTask = nil
        remoteHelperSession?.stop()
        remoteHelperSession = nil
        watcherSource?.cancel()
        watcherSource = nil
        watcherFD = -1
        cancelMoveLookup()
    }

    private func startRemoteConflictPolling() {
        guard let host = remoteHost else { return }
        remotePollTask?.cancel()
        remotePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.remoteHelperSession?.isAvailable == true
                    ? Self.remoteHelperSafetyNetNanos
                    : Self.remoteConflictPollNanos
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await checkRemoteConflict(host: host)
                remoteHelperSession?.retryIfNeeded()
            }
        }
    }

    private func startRemoteHelperWatching(host: String) {
        guard remoteHelperSession == nil else { return }
        let watchedRoot = absoluteFileURL.deletingLastPathComponent()
        let fileWatchMatcher = RemoteHelperFileWatchMatcher(
            targetURL: absoluteFileURL,
            watchedRootURL: watchedRoot
        )
        let session = RemoteHelperWatchSession(
            host: host,
            root: watchedRoot.path,
            kinds: [.files]
        )
        session.onEvent = { [weak self] event in
            guard let self, event.kind == .files else { return }
            guard fileWatchMatcher.matches(event: event) else { return }
            Task { @MainActor in await self.checkRemoteConflict(host: host) }
        }
        session.onAvailabilityChanged = { [weak self] _ in
            self?.startRemoteConflictPolling()
        }
        remoteHelperSession = session
        session.start()
    }

    private func checkRemoteConflict(host: String) async {
        guard remoteConflictChecks.beginOrMarkPending() else { return }
        repeat {
            await checkRemoteConflictOnce(host: host)
        } while remoteConflictChecks.finishCheck()
    }

    private func checkRemoteConflictOnce(host: String) async {
        guard !remoteSaveInFlight else { return }
        do {
            guard let mtime = try await RemoteFileAccess.mtime(host: host, path: absoluteFileURL.path) else {
                if dirty { conflict = .deletedOnDisk }
                return
            }
            RemoteHostStatusStore.shared.reportSuccess(host: host)
            guard mtime > originalMtime else { return }
            if dirty {
                conflict = .changedOnDisk
            } else {
                revert()
            }
        } catch {
            if case .connectionFailed = error as? RemoteFileAccessError {
                RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
            }
        }
    }

    private func handleWatcherEvent() {
        let url = worktreeRoot.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            watcherSource?.cancel()
            watcherSource = nil
            watcherFD = -1
            startMoveLookupForMissingFile(at: url)
            return
        }
        cancelMoveLookup()
        // A load is already in-flight (initial load or a previous watcher-
        // triggered revert). It will pick up the latest content, so skip —
        // without this guard, two rapid watcher events (e.g. .write + .attrib)
        // each fire revert(), both async loads apply, and observers fire twice.
        if queueReloadDuringLoadIfNeeded() {
            return
        }
        guard let onDiskMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
              onDiskMtime != originalMtime else { return }
        if dirty {
            conflict = .changedOnDisk
            return
        }
        revert()
        // Re-arm watcher in case rename swapped the inode (atomic save by an
        // external tool).
        startWatching()
    }

    private func startMoveLookupForMissingFile(at missingURL: URL) {
        guard remoteHost == nil else { return }
        guard moveLookupTask == nil else { return }
        guard let originalIdentity else {
            markDeletedConflictIfNeeded()
            return
        }

        moveLookupGeneration &+= 1
        let generation = moveLookupGeneration
        let requestedRelativePath = relativePath
        let worktreeRoot = worktreeRoot
        let lookupTask = Task.detached(priority: .utility) {
            Self.findMovedRelativePath(
                worktreeRoot: worktreeRoot,
                originalIdentity: originalIdentity
            )
        }
        moveLookupTask = lookupTask

        Task { @MainActor [weak self] in
            let result = await lookupTask.value
            guard let self,
                  self.moveLookupGeneration == generation,
                  !Task.isCancelled else { return }
            self.moveLookupTask = nil
            self.finishMoveLookup(
                result,
                requestedRelativePath: requestedRelativePath,
                missingURL: missingURL
            )
        }
    }

    private func finishMoveLookup(_ result: MovedFileLookupResult?, requestedRelativePath: String, missingURL: URL) {
        guard relativePath == requestedRelativePath else { return }
        if let result {
            followMovedFile(to: result.relativePath)
            return
        }
        if FileManager.default.fileExists(atPath: missingURL.path) {
            handleRecreatedOriginalPath(at: missingURL)
        } else {
            markDeletedConflictIfNeeded()
        }
    }

    private func handleRecreatedOriginalPath(at url: URL) {
        if dirty {
            if Self.movedFileDiffersFromOriginal(at: url, originalMtime: originalMtime, originalText: originalText) {
                conflict = .changedOnDisk
            } else {
                updateOriginalFileIdentity(from: url)
            }
            startWatching()
            return
        }

        if Self.movedFileDiffersFromOriginal(at: url, originalMtime: originalMtime, originalText: originalText) {
            revert()
        } else {
            updateOriginalFileIdentity(from: url)
        }
        startWatching()
    }

    #if DEBUG
    func handleRecreatedOriginalPathForTest() {
        handleRecreatedOriginalPath(at: worktreeRoot.appendingPathComponent(relativePath))
    }

    func finishMoveLookupForTest(movedRelativePath: String?, missingRelativePath: String? = nil) {
        finishMoveLookup(
            movedRelativePath.map(MovedFileLookupResult.init(relativePath:)),
            requestedRelativePath: relativePath,
            missingURL: worktreeRoot.appendingPathComponent(missingRelativePath ?? relativePath)
        )
    }
    #endif

    private func markDeletedConflictIfNeeded() {
        if dirty {
            conflict = .deletedOnDisk
        }
        // If the buffer is clean and the file vanished, leave the buffer
        // contents in place. The next ⌘S will hit `save()`'s
        // moveItem-when-target-missing branch and recreate the file.
        // No conflict raised — we have nothing to lose.
    }

    private func cancelMoveLookup() {
        moveLookupGeneration &+= 1
        moveLookupTask?.cancel()
        moveLookupTask = nil
    }

    private func followMovedFile(to newRelativePath: String, movedFileDiffersFromOriginal: Bool? = nil) {
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let oldRelativePath = relativePath
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let wasDirty = dirty
        guard shouldFollowPathChange?(oldRelativePath, newRelativePath) ?? true else {
            if wasDirty {
                conflict = .deletedOnDisk
            }
            return
        }
        stopWatching()
        // Cancel any in-flight language-override transition so its captured
        // URL (the pre-rename path) can't fire a stale didOpen at the old
        // URI after we've already moved on.
        languageReopenTask?.cancel()
        languageReopenTask = nil
        relativePath = newRelativePath
        language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
        if wasDirty {
            updateOriginalFileIdentity(from: newURL)
            let differsFromOriginal = movedFileDiffersFromOriginal ?? Self.movedFileDiffersFromOriginal(
                at: newURL,
                originalMtime: originalMtime,
                originalText: originalText
            )
            conflict = differsFromOriginal ? .changedOnDisk : nil
            snapshotNow()
        } else {
            loadFromDisk { [weak self] _ in
                guard let self else { return }
                self.discardSnapshot()
                self.handleEdit(edit: nil)
                self.notifyDidOpen()
            }
        }
        notifyDidClose(url: oldURL)
        if wasDirty {
            notifyDidOpen()
        }
        onPathChanged?(oldRelativePath, newRelativePath)
        startWatching()
    }

    func resolveConflictKeepingMine() {
        if let host = remoteHost {
            remoteOverwriteAfterConflict = true
            let mtimeProbeGeneration = remoteSaveGeneration
            let path = absoluteFileURL.path
            Task { @MainActor [weak self] in
                do {
                    if let mtime = try await RemoteFileAccess.mtime(host: host, path: path) {
                        guard let self,
                              self.remoteSaveGeneration == mtimeProbeGeneration,
                              self.remoteOverwriteAfterConflict else { return }
                        self.originalMtime = mtime
                    }
                    RemoteHostStatusStore.shared.reportSuccess(host: host)
                } catch {
                    if case .connectionFailed = error as? RemoteFileAccessError {
                        RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
                    }
                }
            }
            conflict = nil
            return
        }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
            originalMtime = mtime
        }
        conflict = nil
    }

    func resolveConflictReloadingFromDisk() {
        revert()
        conflict = nil
        startWatching()
    }

    /// Persist the buffer to disk atomically. Writes to a temp file in the
    /// same directory, fsyncs, renames onto the target, and restores the
    /// captured POSIX permissions on the new inode. Updates `originalText`,
    /// `originalMtime`, and clears `dirty`. Throws on any IO failure; the
    /// buffer is left dirty so the user can retry.
    func save() throws {
        lastSaveError = nil
        guard !readOnly else { return }
        switch saveDisposition {
        case .blockedByLoad:
            throw SaveError.loadPending
        case .clean where isLoading:
            return
        case .clean, .ready:
            break
        }
        if remoteHost != nil {
            throw SaveError.remoteSaveRequiresAwait
        }
        try saveLocal()
    }

    func saveAwaitingRemote() async throws {
        lastSaveError = nil
        guard !readOnly else { return }
        switch saveDisposition {
        case .blockedByLoad:
            throw SaveError.loadPending
        case .clean where isLoading:
            return
        case .clean, .ready:
            break
        }
        if let host = remoteHost {
            try await saveRemote(host: host)
            return
        }
        try saveLocal()
    }

    private func saveLocal() throws {
        let url = worktreeRoot.appendingPathComponent(relativePath)
        if dirty,
           let onDiskMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
           onDiskMtime != originalMtime {
            conflict = .changedOnDisk
            throw SaveError.loadPending
        }
        if conflict == .changedOnDisk { throw SaveError.loadPending }
        let canonical = storage.string
        try write(canonical: canonical, to: url, createDirectories: false)
        originalText = canonical
        updateOriginalMtime(from: url)
        startWatching()
        discardSnapshot()
        notifyDidSave(url: url)
    }

    /// Remote writes must not block the main actor. Keep the buffer dirty and
    /// its hot-exit snapshot intact until the SSH write is confirmed.
    private func saveRemote(host: String) async throws {
        remoteSaveGeneration += 1
        let generation = remoteSaveGeneration
        let canonical = storage.string
        let serialized = lineEnding.normalize(canonical)
        var priorOriginalText = originalText
        let path = absoluteFileURL.path

        do {
            while remoteSaveInFlight {
                try await Task.sleep(nanoseconds: 25_000_000)
                guard remoteSaveGeneration == generation else { return }
            }
            guard remoteSaveGeneration == generation else { return }
            remoteSaveInFlight = true
            defer {
                remoteSaveInFlight = false
            }

            try await verifyRemoteFileContained(host: host, path: path)
            priorOriginalText = originalText
            let baseline = originalMtime
            let shouldOverwriteConflict = remoteOverwriteAfterConflict
            let newMtime: Date
            do {
                newMtime = try await RemoteFileAccess.write(
                    host: host,
                    path: path,
                    content: serialized,
                    expectedMtime: shouldOverwriteConflict ? nil : baseline,
                    expectedContent: shouldOverwriteConflict
                        ? nil
                        : lineEnding.normalize(priorOriginalText)
                )
            } catch RemoteFileAccessError.saveConflict(let conflict) {
                guard remoteSaveGeneration == generation else { return }
                rollbackRemoteSave(
                    to: priorOriginalText,
                    conflict: conflict == .deleted ? .deletedOnDisk : .changedOnDisk
                )
                throw SaveError.remoteSaveConflict
            }
            guard remoteSaveGeneration == generation else {
                originalText = canonical
                originalMtime = newMtime
                RemoteHostStatusStore.shared.reportSuccess(host: host)
                return
            }
            originalText = canonical
            originalMtime = newMtime
            remoteOverwriteAfterConflict = false
            discardSnapshot()
            notifyDidSave(url: absoluteFileURL)
            RemoteHostStatusStore.shared.reportSuccess(host: host)
        } catch {
            if case .connectionFailed = error as? RemoteFileAccessError {
                RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
            }
            rollbackRemoteSave(to: priorOriginalText, error: error)
            throw error
        }
    }

    private func rollbackRemoteSave(to originalText: String, conflict: Conflict) {
        self.originalText = originalText
        self.conflict = conflict
    }

    private func rollbackRemoteSave(to originalText: String, error: Error) {
        self.originalText = originalText
        switch error {
        case let RemoteFileAccessError.connectionFailed(detail):
            lastSaveError = "Unable to save remote file: \(detail)"
        case let RemoteFileAccessError.writeFailed(detail):
            lastSaveError = "Unable to save remote file: \(detail)"
        case RemoteFileAccessError.saveConflict:
            lastSaveError = "The remote file changed before it could be saved."
        default:
            lastSaveError = (error as NSError).localizedDescription
        }
    }

    private func remotePathOperationError() -> NSError {
        NSError(
            domain: "EditorBuffer",
            code: 100,
            userInfo: [
                NSLocalizedDescriptionKey: "Renaming or moving files is not yet supported for remote projects."
            ]
        )
    }

    func saveAs(relativePath newRelativePath: String) throws {
        lastSaveError = nil
        guard !readOnly else { return }
        guard !isLoading else { throw SaveError.loadPending }
        if remoteHost != nil { throw remotePathOperationError() }
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let canonical = storage.string
        stopWatching()
        languageReopenTask?.cancel()
        languageReopenTask = nil
        do {
            try write(canonical: canonical, to: newURL, createDirectories: true)
            relativePath = newRelativePath
            language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
            originalText = canonical
            updateOriginalMtime(from: newURL)
            updateOriginalFileIdentity(from: newURL)
            discardSnapshot()
            notifyDidClose(url: oldURL)
            notifyDidOpen()
            notifyDidSave(url: newURL)
            onPathChanged?(oldURLRelativePath(from: oldURL), newRelativePath)
            startWatching()
        } catch {
            startWatching()
            throw error
        }
    }

    func moveTo(relativePath newRelativePath: String) throws {
        lastSaveError = nil
        guard !readOnly else { return }
        guard !isLoading else { throw SaveError.loadPending }
        if remoteHost != nil { throw remotePathOperationError() }
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        stopWatching()
        languageReopenTask?.cancel()
        languageReopenTask = nil
        do {
            try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: newURL.path) {
                guard sameExistingFile(oldURL, newURL) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try renameItem(at: oldURL, to: newURL)
            } else {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            }
            relativePath = newRelativePath
            language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
            updateOriginalMtime(from: newURL)
            updateOriginalFileIdentity(from: newURL)
            if dirty {
                snapshotNow()
            } else {
                discardSnapshot()
            }
            notifyDidClose(url: oldURL)
            notifyDidOpen()
            onPathChanged?(oldURLRelativePath(from: oldURL), newRelativePath)
            startWatching()
        } catch {
            startWatching()
            throw error
        }
    }

    func saveAsRemote(relativePath newRelativePath: String) async throws {
        guard let host = remoteHost else { throw remotePathOperationError() }
        guard !readOnly else { return }
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
        lastSaveError = nil
        let oldURL = absoluteFileURL
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let canonical = storage.string
        stopWatching()
        languageReopenTask?.cancel()
        languageReopenTask = nil
        do {
            try await verifyRemoteFileContained(host: host, path: newURL.path)
            let available = try await RemoteExec.run(
                host: host, cwd: nil,
                command: "p=\(SSHCommand.shellQuote(newURL.path)); [ ! -e \"$p\" ] && [ ! -L \"$p\" ]",
                timeout: 15
            )
            guard available.exitCode == 0 else {
                throw CocoaError(.fileWriteFileExists)
            }
            let mkdir = try await RemoteExec.run(
                host: host, cwd: nil,
                command: RemoteFileOps.mkdirCommand(parentOf: newURL.path), timeout: 15
            )
            guard mkdir.exitCode == 0 else {
                throw NSError(domain: "EditorBuffer", code: 101, userInfo: [
                    NSLocalizedDescriptionKey: "Could not create the remote directory: \(mkdir.stderr)"
                ])
            }
            let mtime = try await RemoteFileAccess.write(
                host: host, path: newURL.path, content: lineEnding.normalize(canonical)
            )
            relativePath = newRelativePath
            language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
            originalText = canonical
            originalMtime = mtime
            discardSnapshot()
            notifyDidClose(url: oldURL)
            notifyDidOpen(url: newURL, text: canonical)
            notifyDidSave(url: newURL)
            onPathChanged?(oldURLRelativePath(from: oldURL), newRelativePath)
            startWatching()
        } catch {
            startWatching()
            throw error
        }
    }

    func moveToRemote(relativePath newRelativePath: String) async throws {
        guard let host = remoteHost else { throw remotePathOperationError() }
        guard !readOnly else { return }
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
        lastSaveError = nil
        let oldURL = absoluteFileURL
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        stopWatching()
        languageReopenTask?.cancel()
        languageReopenTask = nil
        do {
            try await verifyRemoteFileContained(host: host, path: newURL.path)
            let moved = try await RemoteExec.run(
                host: host, cwd: nil,
                command: RemoteFileOps.moveCommand(from: oldURL.path, to: newURL.path), timeout: 15
            )
            guard moved.exitCode == 0 else {
                throw NSError(domain: "EditorBuffer", code: 102, userInfo: [
                    NSLocalizedDescriptionKey: "Could not move the remote file: \(moved.stderr)"
                ])
            }
            relativePath = newRelativePath
            language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
            if dirty { snapshotNow() } else { discardSnapshot() }
            notifyDidClose(url: oldURL)
            notifyDidOpen(url: newURL, text: storage.string)
            onPathChanged?(oldURLRelativePath(from: oldURL), newRelativePath)
            startWatching()
        } catch {
            startWatching()
            throw error
        }
    }

    private func sameExistingFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftValues = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let rightValues = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let leftFile = leftValues.fileResourceIdentifier,
              let rightFile = rightValues.fileResourceIdentifier,
              let leftVolume = leftValues.volumeIdentifier,
              let rightVolume = rightValues.volumeIdentifier else { return false }
        return (leftFile as AnyObject).isEqual(rightFile)
            && (leftVolume as AnyObject).isEqual(rightVolume)
    }

    private struct FileIdentity: @unchecked Sendable {
        let file: AnyObject
        let volume: AnyObject

        func matches(file: Any, volume: Any) -> Bool {
            (file as AnyObject).isEqual(self.file)
                && (volume as AnyObject).isEqual(self.volume)
        }
    }

    private struct MovedFileLookupResult: Sendable {
        let relativePath: String
    }

    private var originalIdentity: FileIdentity? {
        guard let originalFileIdentifier, let originalVolumeIdentifier else { return nil }
        return FileIdentity(file: originalFileIdentifier, volume: originalVolumeIdentifier)
    }

    private func renameItem(at oldURL: URL, to newURL: URL) throws {
        if remoteHost != nil { throw remotePathOperationError() }
        guard oldURL.path != newURL.path else { return }
        if Darwin.rename(oldURL.path, newURL.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func write(canonical: String, to url: URL, createDirectories: Bool) throws {
        let onDisk = lineEnding.normalize(canonical)
        let dir = url.deletingLastPathComponent()
        if createDirectories {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).alas-\(UUID().uuidString).tmp")
        let data = Data(onDisk.utf8)

        // Write + fsync. We open with O_WRONLY|O_CREAT|O_TRUNC so a leftover
        // tmp from a crashed prior save is overwritten, not appended to.
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 {
            // Defensive: POSIX open(2) shouldn't create the file when returning
            // -1, but some filesystem edge cases can leave a zero-byte tmp file.
            // Clean it up so a later save attempt doesn't trip over it.
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    try? FileManager.default.removeItem(at: tmp)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        if Darwin.fsync(fd) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Atomic rename. `replaceItemAt` preserves the original inode's xattrs
        // when available; if the target doesn't exist (deleted on disk), fall
        // back to moveItem.
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // Restore captured perms; failure is non-fatal (file is saved, just
        // not with our preferred mode).
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: UInt16(permissions))], ofItemAtPath: url.path)
    }

    private func updateOriginalMtime(from url: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            originalMtime = mtime
        }
        updateOriginalFileIdentity(from: url)
    }

    private func updateOriginalFileAttributes(from url: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            originalMtime = (attrs[.modificationDate] as? Date) ?? originalMtime
            if let nsPerms = attrs[.posixPermissions] as? NSNumber {
                permissions = mode_t(nsPerms.uint16Value)
            }
        }
        updateOriginalFileIdentity(from: url)
    }

    private func updateOriginalFileIdentityAndPermissions(from url: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let nsPerms = attrs[.posixPermissions] as? NSNumber {
            permissions = mode_t(nsPerms.uint16Value)
        }
        updateOriginalFileIdentity(from: url)
    }

    private func updateOriginalFileIdentity(from url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let file = values.fileResourceIdentifier,
              let volume = values.volumeIdentifier else {
            originalFileIdentifier = nil
            originalVolumeIdentifier = nil
            return
        }
        originalFileIdentifier = file as AnyObject
        originalVolumeIdentifier = volume as AnyObject
    }

    private static let movedFileSearchSkippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".gradle",
        ".next",
        ".pnpm-store",
        ".swiftpm",
        ".turbo",
        ".yarn",
        "DerivedData",
        "build",
        "node_modules"
    ]

    nonisolated private static func findMovedRelativePath(
        worktreeRoot: URL,
        originalIdentity: FileIdentity
    ) -> MovedFileLookupResult? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(
            at: worktreeRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return nil }

        for case let candidate as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? candidate.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true,
               movedFileSearchSkippedDirectoryNames.contains(candidate.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  let file = values.fileResourceIdentifier,
                  let volume = values.volumeIdentifier,
                  originalIdentity.matches(file: file, volume: volume),
                  let relativePath = relativePath(for: candidate, worktreeRoot: worktreeRoot) else { continue }
            return MovedFileLookupResult(relativePath: relativePath)
        }
        return nil
    }

    nonisolated private static func movedFileDiffersFromOriginal(at url: URL, originalMtime: Date, originalText: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return true }
        if mtime != originalMtime { return true }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return LineEnding.lf.normalize(raw) != originalText
    }

    private func relativePath(for url: URL) -> String? {
        Self.relativePath(for: url, worktreeRoot: worktreeRoot)
    }

    nonisolated private static func relativePath(for url: URL, worktreeRoot: URL) -> String? {
        let root = worktreeRoot.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    private func oldURLRelativePath(from url: URL) -> String {
        relativePath(for: url) ?? relativePath
    }

    /// Reconcile `openedLanguage` with `effectiveLanguage`. Closes the
    /// document on the previous holder (if any) and reopens it on the new
    /// language (if any). Skipped for external buffers — those route via a
    /// different external-document API.
    private func applyEffectiveLanguageToLSP() {
        guard initialLoadFinished, !isExternal, lsp != nil else { return }
        cancelPendingLSPOpen()
        let prior = languageReopenTask
        // Cancel the prior queued transition before we await it — this
        // propagates cancellation through the chain. `close()` only cancels
        // the latest `languageReopenTask`, but since each new task cancels
        // its predecessor at start, an older queued task gets cancelled too
        // and never reaches its LSP hops post-teardown.
        prior?.cancel()
        // `openedLanguage` is intentionally NOT mutated synchronously here.
        // If we did, a concurrent `close()` (e.g. tab closed immediately
        // after the override flip) would read the *new* languageId from
        // `openedLanguage` and try to didClose it on a holder that never
        // received didOpen — leaving the old holder's refcount unbalanced.
        // The Task body below updates `openedLanguage` only after each LSP
        // hop actually completes, and re-reads `effectiveLanguage` and
        // `previous` at execution time so chained transitions observe the
        // real post-prior-task state.
        languageReopenTask = Task { [weak self] in
            await prior?.value
            if Task.isCancelled { return }
            guard let self, let lsp = self.lsp else { return }
            let previous = self.openedLanguage
            let target = self.effectiveLanguage
            guard target != previous else { return }
            // Re-read the URL inside the Task so a rename/move that landed
            // during the prior-task / close await still targets the current
            // path. Snapshotting outside the Task would leave the reopen
            // attached to the pre-rename URI, leaking refs.
            let url = self.worktreeRoot.appendingPathComponent(self.relativePath)
            let worktreeRootCapture = self.worktreeRoot
            if let previous {
                await lsp.closeDocument(worktreeRoot: worktreeRootCapture, fileURL: url, languageId: previous)
                if Task.isCancelled { return }
                self.openedLanguage = nil
            }
            if let target {
                let text = self.storage.string
                let opened = await lsp.openDocument(
                    worktreeRoot: worktreeRootCapture,
                    fileURL: url,
                    languageId: target,
                    text: text
                ) != nil
                if Task.isCancelled {
                    // openDocument has already bumped refs on the server
                    // (the ref bump happens synchronously inside the
                    // manager before its first await). `close()` would
                    // have read `openedLanguage == nil` and skipped its
                    // didClose, so without this compensation the doc
                    // would be left referenced with no owning buffer.
                    if opened {
                        await lsp.closeDocument(worktreeRoot: worktreeRootCapture, fileURL: url, languageId: target)
                    }
                    return
                }
                if opened {
                    self.openedLanguage = target
                }
            }
        }
    }

    private func notifyDidSave(url: URL) {
        if let lsp, let opened = openedLanguage {
            Task { await lsp.didSave(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: opened) }
        }
    }

    private func notifyDidClose(url: URL) {
        cancelPendingLSPOpen()
        if let lsp, let opened = openedLanguage {
            Task { await lsp.closeDocument(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: opened) }
            openedLanguage = nil
        }
    }

    private func notifyDidOpen() {
        openLSPDocumentIfReady()
    }

    private func notifyDidOpen(url: URL, text: String) {
        guard remoteHost != nil else {
            notifyDidOpen()
            return
        }
        guard initialLoadFinished,
              !isExternal,
              openedLanguage == nil,
              let lsp,
              let effective = effectiveLanguage
        else { return }
        openedLanguage = effective
        let worktreeRoot = worktreeRoot
        Task { await lsp.openDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: effective, text: text) }
    }

    func saveRecordingError() throws {
        do {
            try save()
        } catch {
            lastSaveError = (error as NSError).localizedDescription
            throw error
        }
    }

    func saveRecordingErrorAwaitingRemote() async throws {
        do {
            try await saveAwaitingRemote()
        } catch {
            lastSaveError = (error as NSError).localizedDescription
            throw error
        }
    }

    func saveConflictKeepingMineAwaitingRemote() async throws {
        let isRemote = remoteHost != nil
        if isRemote {
            remoteOverwriteAfterConflict = true
        }
        do {
            try await saveRecordingErrorAwaitingRemote()
            conflict = nil
        } catch {
            if isRemote {
                remoteOverwriteAfterConflict = false
            }
            throw error
        }
    }

    func formatAndSaveRecordingError(config: AppConfig.Code, lsp: DocumentFormatter?, formattingTimeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        do {
            try await formatAndSave(config: config, lsp: lsp, formattingTimeoutNanoseconds: formattingTimeoutNanoseconds)
        } catch {
            lastSaveError = (error as NSError).localizedDescription
            throw error
        }
    }

    // MARK: - Format-on-save

    /// Best-effort formatting before save. Falls back to plain save when
    /// formatting is disabled, unavailable, fails, times out, or the buffer
    /// changed while the formatter was in flight.
    func formatAndSave(config: AppConfig.Code, lsp: DocumentFormatter?, formattingTimeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        guard !readOnly, !isExternal else {
            try await saveAwaitingRemote()
            return
        }
        guard config.formatOnSave, let lsp else {
            try await saveAwaitingRemote()
            return
        }
        // Prefer the user's runtime override, then whatever the server
        // currently has open (which already accounts for override and
        // post-init transitions), then fall back to the inferred language
        // or a fresh registry lookup. Without this, an overridden tab
        // would silently format against the original language's server
        // (or no server at all for unknown-extension overrides).
        let resolvedLanguage = languageOverride
            ?? openedLanguage
            ?? language
            ?? lsp.language(forFileExtension: ((relativePath as NSString).pathExtension))
        guard let resolvedLanguage else {
            try await saveAwaitingRemote()
            return
        }
        let generation = editGeneration
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let text = storage.string
        await lsp.didChange(worktreeRoot: worktreeRoot, fileURL: url, languageId: resolvedLanguage, text: text, edits: nil)
        let options = LSPFormattingOptions(tabSize: 4, insertSpaces: true)
        let edits: [LSPTextEdit]? = await requestFormatting(lsp: lsp, url: url, language: resolvedLanguage, options: options, timeoutNanoseconds: formattingTimeoutNanoseconds)
        guard editGeneration == generation else {
            try await saveAwaitingRemote()
            return
        }
        guard let edits, !edits.isEmpty else {
            try await saveAwaitingRemote()
            return
        }
        guard applyFormattingEdits(edits) else {
            try await saveAwaitingRemote()
            return
        }
        let formattedText = storage.string
        await lsp.didChange(worktreeRoot: worktreeRoot, fileURL: url, languageId: resolvedLanguage, text: formattedText, edits: nil)
        try await saveAwaitingRemote()
    }

    private func requestFormatting(lsp: DocumentFormatter, url: URL, language: String, options: LSPFormattingOptions, timeoutNanoseconds: UInt64) async -> [LSPTextEdit]? {
        let formatTask: Task<[LSPTextEdit]?, Never> = Task { [weak self] in
            guard self != nil else { return nil }
            return await lsp.formatting(for: url, languageId: language, options: options)
        }
        let timeoutTask = Task { try? await Task.sleep(nanoseconds: timeoutNanoseconds) }
        return await withCheckedContinuation { (cont: CheckedContinuation<[LSPTextEdit]?, Never>) in
            var didResume = false
            func finish(_ value: [LSPTextEdit]?) {
                guard !didResume else { return }
                didResume = true
                cont.resume(returning: value)
            }
            Task {
                let edits = await formatTask.value
                timeoutTask.cancel()
                finish(edits)
            }
            Task {
                try? await timeoutTask.value
                formatTask.cancel()
                finish(nil)
            }
        }
    }

    /// Convert and apply LSP edits in reverse document order so offsets do
    /// not shift. Returns `false` if any edit range is invalid, leaving the
    /// buffer untouched.
    private func applyFormattingEdits(_ edits: [LSPTextEdit]) -> Bool {
        let text = storage.string
        var nsEdits: [(range: NSRange, newText: String)] = []
        for edit in edits {
            guard let start = TextEditCoordinates.utf16Offset(from: edit.range.start, in: text),
                  let end = TextEditCoordinates.utf16Offset(from: edit.range.end, in: text),
                  start <= end, end <= (text as NSString).length else { return false }
            nsEdits.append((NSRange(location: start, length: end - start), edit.newText))
        }
        let ascending = nsEdits.sorted { first, second in
            if first.range.location == second.range.location {
                return first.range.length < second.range.length
            }
            return first.range.location < second.range.location
        }
        for index in ascending.indices.dropFirst() {
            guard NSMaxRange(ascending[index - 1].range) <= ascending[index].range.location else {
                return false
            }
        }
        withLoadEditTrackingSuppressed {
            storage.beginEditing()
            for edit in ascending.reversed() {
                storage.replaceCharacters(in: edit.range, with: edit.newText)
            }
            storage.endEditing()
        }
        editGeneration &+= 1
        return true
    }

    // MARK: - Snapshot / restore (hot-exit)

    private func applySnapshot(_ snap: EditorBufferStore.Snapshot) {
        guard canRestoreSnapshotPath(snap.relativePath) else {
            discardSnapshot()
            return
        }
        let oldRelativePath = relativePath
        relativePath = snap.relativePath
        if oldRelativePath != snap.relativePath {
            pendingRestoredPathChange = (oldRelativePath, snap.relativePath)
        }
        language = lsp?.language(forFileExtension: (snap.relativePath as NSString).pathExtension)
        withLoadEditTrackingSuppressed {
            storage.setAttributedString(NSAttributedString(string: snap.content))
        }
        originalText = snap.originalText
        originalMtime = snap.originalMtime
        lineEnding = snap.lineEnding
        // Keep restored remote drafts dirty until async load/save establishes
        // whether the on-host baseline changed while the app was closed.
        restoredRemoteSnapshot = remoteHost != nil
        readOnly = false
        if remoteHost == nil {
            updateOriginalFileIdentityAndPermissions(from: worktreeRoot.appendingPathComponent(snap.relativePath))
        }
    }

    private func replayPendingUserEdits(_ edits: [EditorTextEdit], fallbackText: String) {
        var merged = storage.string
        for edit in edits {
            guard let next = TextEditCoordinates.apply(edit, to: merged) else {
                withLoadEditTrackingSuppressed {
                    storage.setAttributedString(NSAttributedString(string: fallbackText))
                }
                return
            }
            merged = next
        }
        withLoadEditTrackingSuppressed {
            storage.setAttributedString(NSAttributedString(string: merged))
        }
    }

    private func canRestoreSnapshotPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              !(path as NSString).isAbsolutePath else { return false }
        let rootPath = worktreeRoot.standardizedFileURL.path
        let targetPath = worktreeRoot.appendingPathComponent(path).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix)
    }

    private func scheduleSnapshot() {
        guard store != nil, worktreeId != nil, tabId != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let onSnapshotRequested = self.onSnapshotRequested {
                    onSnapshotRequested()
                } else {
                    self.snapshotNow()
                }
            }
        }
    }

    /// Writes an immediate snapshot if the buffer is dirty and hot-exit is
    /// enabled (store/worktreeId/tabId all set on the production init).
    /// Safe to call from any state — clean buffers discard stale snapshots,
    /// while buffers without a store remain a no-op.
    func snapshotNow(tabId overrideTabId: String? = nil) {
        guard let store, let worktreeId, let tabId else { return }
        let snapshotTabId = overrideTabId ?? tabId
        guard dirty else {
            store.discard(worktreeId: worktreeId, tabId: snapshotTabId)
            return
        }
        let snap = EditorBufferStore.Snapshot(
            relativePath: relativePath,
            content: storage.string,
            originalText: originalText,
            originalMtime: originalMtime,
            lineEnding: lineEnding
        )
        try? store.write(snap, worktreeId: worktreeId, tabId: snapshotTabId)
    }

    private func discardSnapshot() {
        if let onDiscardSnapshotsRequested {
            onDiscardSnapshotsRequested()
            return
        }
        guard let store, let worktreeId, let tabId else { return }
        store.discard(worktreeId: worktreeId, tabId: tabId)
    }

    /// Tear-down for a buffer. App quit paths can keep a final dirty snapshot
    /// for hot-exit restore; explicit tab removal discards it.
    func close(persistDirtySnapshot: Bool = true) {
        cancelPendingLoad()
        cancelPendingLSPOpen()
        snapshotTask?.cancel()
        // Cancel any in-flight language-override reopen so it can't run
        // `openDocument` after close() has already torn down the buffer —
        // that would leak an LSP holder ref nobody owns.
        languageReopenTask?.cancel()
        languageReopenTask = nil
        if persistDirtySnapshot {
            if dirty { snapshotNow() }
        } else {
            discardSnapshot()
        }
        stopWatching()
        if let lsp, let opened = openedLanguage {
            let url = worktreeRoot.appendingPathComponent(relativePath)
            Task { await lsp.closeDocument(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: opened) }
            openedLanguage = nil
        }
    }

    /// Compares the snapshot's recorded original mtime to the current file's
    /// mtime. If they differ, the file changed while we were quit and the
    /// user's snapshot is "their version" against a moved baseline — show
    /// the conflict banner. Called on first display after restore.
    func checkForConflictOnRestore() {
        if remoteHost != nil { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if dirty { conflict = .deletedOnDisk }
            return
        }
        guard let onDiskMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else { return }
        if dirty && onDiskMtime != originalMtime {
            conflict = .changedOnDisk
        }
    }

    private var absoluteFileURL: URL {
        worktreeRoot.appendingPathComponent(relativePath)
    }

    private func setStorageText(_ text: String) {
        withLoadEditTrackingSuppressed {
            storage.setAttributedString(NSAttributedString(string: text))
        }
    }

    private func applyLoadedText(_ raw: String) {
        let detected = LineEnding.detect(in: raw)
        let canonical = LineEnding.lf.normalize(raw)
        storage.setAttributedString(NSAttributedString(string: canonical))
        originalText = canonical
        lineEnding = detected
    }

    private func beginRemoteLoad(host: String, replacingDirty: Bool) {
        remoteLoadGeneration &+= 1
        let generation = remoteLoadGeneration
        let path = absoluteFileURL.path
        if replacingDirty {
            restoredRemoteSnapshot = false
        }
        setStorageText("(loading remote file...)")
        readOnly = true

        Task { @MainActor [weak self] in
            let result: RemoteReadResult
            do {
                guard let self, self.remoteLoadGeneration == generation else { return }
                if let hook = EditorBuffer.remoteReadResultForTesting {
                    result = try await hook(host, path)
                } else {
                    try await self.verifyRemoteFileContained(host: host, path: path)
                    result = try await RemoteFileAccess.read(host: host, path: path)
                }
            } catch {
                guard let self, self.remoteLoadGeneration == generation else { return }
                if case .connectionFailed = error as? RemoteFileAccessError {
                    RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
                }
                if replacingDirty || !self.restoredRemoteSnapshot {
                    self.setStorageText("(unable to read remote file: \(Self.remoteFileErrorDescription(error)))")
                    self.loadKind = .missing
                }
                return
            }

            guard let self, self.remoteLoadGeneration == generation else { return }
            RemoteHostStatusStore.shared.reportSuccess(host: host)
            switch result {
            case .missing, .directory:
                if replacingDirty || !self.restoredRemoteSnapshot {
                    self.setStorageText("(unable to read file)")
                    self.loadKind = .missing
                }
            case .symlink:
                if replacingDirty || !self.restoredRemoteSnapshot {
                    self.setStorageText("(read-only: remote symbolic links are not editable)")
                    self.loadKind = .loaded
                }
                self.readOnly = true
            case let .unreadable(detail):
                if replacingDirty || !self.restoredRemoteSnapshot {
                    self.setStorageText("(unable to read remote file: \(detail))")
                    self.loadKind = .missing
                }
            case let .file(data, mtime):
                guard let raw = String(data: data, encoding: .utf8) else {
                    if replacingDirty || !self.restoredRemoteSnapshot {
                        self.setStorageText("(read-only: file is not valid UTF-8)")
                        self.loadKind = .notUTF8
                    }
                    return
                }
                if self.restoredRemoteSnapshot {
                    self.restoredRemoteSnapshot = false
                    self.markRemoteFileEditable()
                    if self.storage.string != self.originalText, mtime != self.originalMtime {
                        self.conflict = .changedOnDisk
                    }
                    self.loadKind = .loaded
                    self.startWatching()
                    self.openRemoteLSPIfNeeded()
                    return
                }
                self.withLoadEditTrackingSuppressed {
                    self.applyLoadedText(raw)
                }
                self.handleEdit(edit: nil)
                self.originalMtime = mtime
                self.markRemoteFileEditable()
                self.loadKind = .loaded
                self.startWatching()
                self.openRemoteLSPIfNeeded()
            }
        }
    }

    private func verifyRemoteFileContained(host: String, path: String) async throws {
        try await RemotePathContainment.verifyRemoteContainment(
            host: host,
            path: path,
            worktreeRoot: worktreeRoot.path
        )
    }

    private static func remoteFileErrorDescription(_ error: Error) -> String {
        switch error {
        case let RemoteFileAccessError.connectionFailed(detail):
            return detail.isEmpty ? "host unreachable" : detail
        case let RemotePathContainment.ContainmentError.outsideWorktree(path):
            return "path is outside the worktree: \(path)"
        default:
            return (error as NSError).localizedDescription
        }
    }

    private func markRemoteFileEditable() {
        // Remote symlinks return `.symlink` before bytes are read, so only
        // ordinary remote files reach this state transition.
        readOnly = false
    }

    private func openRemoteLSPIfNeeded() {
        guard !isExternal,
              remoteHost != nil,
              openedLanguage == nil,
              let lsp,
              let language
        else { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        openedLanguage = language
        let text = storage.string
        Task { await lsp.openDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: language, text: text) }
    }

    /// Load the file from disk, calling `completion` on the main actor
    /// when the content has been applied. The file read happens in a
    /// `Task.detached` so the main thread isn't blocked by
    /// `String(contentsOf:)` on large files.
    private func loadFromDisk(
        preservePendingEdits: Bool = false,
        replacingDirty: Bool = false,
        notifyAfterLoad: Bool = true,
        hasPendingSnapshot: Bool = false,
        completion: @escaping @MainActor (LoadState.Pending?) -> Void
    ) {
        if let remoteHost {
            let generation = beginAsyncLoad(hasPendingSnapshot: hasPendingSnapshot)
            beginRemoteLoad(host: remoteHost, replacingDirty: replacingDirty)
            if let pending = acceptLoadCompletion(generation: generation) {
                completion(preservePendingEdits ? pending : nil)
            }
            return
        }
        let url = absoluteFileURL
        let resolvedURL = url.resolvingSymlinksInPath()
        let isExternal = self.isExternal
        let generation = beginAsyncLoad(hasPendingSnapshot: hasPendingSnapshot)
        let task = Task.detached(priority: .userInitiated) { () -> LoadResult in
            if let gate = await EditorBuffer.loadGateForTesting {
                await gate()
            }
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                return .missing
            }
            let isDirectory = (try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory { return .missing }
            if let override = await EditorBuffer.loadResultForTesting,
               let raw = await override(resolvedURL) {
                let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                return .loaded(raw: raw, resolvedURL: resolvedURL, isExternal: isExternal, isSymlink: isSymlink)
            }
            guard let raw = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
                return .notUTF8
            }
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            return .loaded(raw: raw, resolvedURL: resolvedURL, isExternal: isExternal, isSymlink: isSymlink)
        }
        loadTask = Task { [weak self] in
            let result = await task.value
            // A newer loadFromDisk may have cancelled this task and started
            // its own. Bail out before mutating storage so a stale result
            // can't overwrite a fresher load (e.g. two watcher events firing
            // before the first async read completes).
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self,
                      let pending = self.acceptLoadCompletion(generation: generation) else { return }
                let didApplyChange = self.withLoadEditTrackingSuppressed {
                    self.applyLoadResult(result)
                }
                completion(preservePendingEdits ? pending : nil)
                self.settleQueuedReloadAfterLoad(
                    pending.queuedReload,
                    preservingUserEdits: preservePendingEdits && pending.hasUserEdits
                )
                if notifyAfterLoad, didApplyChange {
                    self.handleEdit(edit: nil)
                }
            }
        }
    }

    private enum LoadResult {
        case missing
        case notUTF8
        case loaded(raw: String, resolvedURL: URL, isExternal: Bool, isSymlink: Bool)
    }

    /// Observable summary of the last `LoadResult`, for SwiftUI views.
    enum LoadKind {
        case loaded
        case missing
        case notUTF8
    }

    @discardableResult
    private func applyLoadResult(_ result: LoadResult) -> Bool {
        switch result {
        case .missing:
            let didApplyChange = storage.string != "(unable to read file)" || !readOnly
            if didApplyChange {
                storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
                readOnly = true
            }
            loadKind = .missing
            return didApplyChange
        case .notUTF8:
            let message = "(read-only: file is not valid UTF-8)"
            let didApplyChange = storage.string != message || !readOnly
            if didApplyChange {
                storage.setAttributedString(NSAttributedString(string: message))
                readOnly = true
            }
            loadKind = .notUTF8
            return didApplyChange
        case .loaded(let raw, let resolvedURL, let isExternal, let isSymlink):
            let detected = LineEnding.detect(in: raw)
            let canonical = LineEnding.lf.normalize(raw)
            let nextReadOnly = (isExternal && !externalEditable) || isSymlink
            let didApplyChange = storage.string != canonical
                || originalText != canonical
                || lineEnding != detected
                || readOnly != nextReadOnly
            if didApplyChange {
                storage.setAttributedString(NSAttributedString(string: canonical))
            }
            originalText = canonical
            lineEnding = detected
            updateOriginalFileAttributes(from: resolvedURL)
            readOnly = nextReadOnly
            loadKind = .loaded
            return didApplyChange
        }
    }

    private func settleQueuedReloadAfterLoad(_ queued: Bool, preservingUserEdits: Bool) {
        guard queued else { return }
        if case .cancelled = loadState { return }
        if preservingUserEdits || dirty {
            conflict = .changedOnDisk
            startWatching()
        } else {
            revert()
            startWatching()
        }
    }

    @discardableResult
    private func loadFromDiskSync() -> Self {
        let url = absoluteFileURL
        let resolvedURL = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            withLoadEditTrackingSuppressed {
                storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
            }
            readOnly = true
            loadKind = .missing
            return self
        }
        let isDirectory = (try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard !isDirectory else {
            withLoadEditTrackingSuppressed {
                storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
            }
            readOnly = true
            loadKind = .missing
            return self
        }
        guard let raw = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            withLoadEditTrackingSuppressed {
                storage.setAttributedString(NSAttributedString(string: "(read-only: file is not valid UTF-8)"))
            }
            readOnly = true
            loadKind = .notUTF8
            return self
        }
        let detected = LineEnding.detect(in: raw)
        let canonical = LineEnding.lf.normalize(raw)
        withLoadEditTrackingSuppressed {
            storage.setAttributedString(NSAttributedString(string: canonical))
        }
        originalText = canonical
        lineEnding = detected
        updateOriginalFileAttributes(from: resolvedURL)
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        readOnly = (isExternal && !externalEditable) || isSymlink
        loadKind = .loaded
        return self
    }

    #if DEBUG
    @discardableResult
    func loadFromDiskSyncForTesting() -> Self {
        loadFromDiskSync()
    }

    /// Wait for any in-flight async disk load to complete. Used by tests
    /// that need to inspect buffer content immediately after init.
    func awaitLoadForTesting() async {
        if let loadTask {
            await loadTask.value
        }
    }

    func handleWatcherEventForTesting() {
        handleWatcherEvent()
    }

    var isWatchingForTesting: Bool {
        watcherSource != nil
    }
    #endif
}

private final class BufferStorageDelegate: NSObject, NSTextStorageDelegate {
    private let onDidProcess: (EditorTextEdit) -> Void

    init(_ onDidProcess: @escaping (EditorTextEdit) -> Void) {
        self.onDidProcess = onDidProcess
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // We only care about character changes (typing, paste, delete).
        // Attribute-only edits (highlighter applying colors) are ignored —
        // otherwise re-highlighting would loop through the observer.
        guard editedMask.contains(.editedCharacters) else { return }
        let replacementText = (textStorage.string as NSString).substring(with: editedRange)
        let oldLength = max(0, editedRange.length - delta)
        let edit = EditorTextEdit(
            location: editedRange.location,
            oldLength: oldLength,
            replacementText: replacementText
        )
        onDidProcess(edit)
    }
}
