import AppKit
import Foundation
import Observation

/// Per-tab editor buffer. Owns the live `NSTextStorage` displayed by
/// `CodeTextView`, plus the original-on-disk snapshot used for dirty
/// detection, save normalization, and conflict resolution.
///
/// Buffers are stored in `TabsManager.buffers` keyed by `TabID` so they
/// outlive the SwiftUI view (which can be torn down and rebuilt). All
/// state mutations happen on the main actor; storage delegate callbacks,
/// LSP responses, and file-watch events are routed through `MainActor`
/// before touching `self`.
@Observable
@MainActor
final class EditorBuffer {
    let worktreeRoot: URL
    private(set) var relativePath: String

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

    private(set) var editGeneration: Int = 0

    @ObservationIgnored
    private var editObservers: [UUID: () -> Void] = [:]
    @ObservationIgnored
    private var storageDelegate: BufferStorageDelegate = .init({})
    @ObservationIgnored
    private var loading = false
    @ObservationIgnored
    private var watcherSource: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var watcherFD: Int32 = -1
    @ObservationIgnored
    private static let watchQueue = DispatchQueue(label: "alas.editor.buffer.watch", qos: .utility)
    @ObservationIgnored
    private let store: EditorBufferStore?
    @ObservationIgnored
    private let worktreeId: String?
    @ObservationIgnored
    private let tabId: String?
    @ObservationIgnored
    private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored
    private let lsp: WorkspaceLSPManager?
    @ObservationIgnored
    private(set) var language: String?

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
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, store: nil, worktreeId: nil, tabId: nil, restoreEnabled: false, lsp: nil)
    }

    /// Production initializer that opts into hot-exit (no LSP). The `store`
    /// is consulted at init time for any persisted snapshot.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: nil)
    }

    /// Production initializer that opts into hot-exit and opens an LSP
    /// document. The buffer owns the LSP open/close lifecycle for this file.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, lsp: WorkspaceLSPManager) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: lsp)
    }

    private init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore?, worktreeId: String?, tabId: String?, restoreEnabled: Bool, lsp: WorkspaceLSPManager?) {
        self.worktreeRoot = worktreeRoot
        self.relativePath = relativePath
        self.storage = NSTextStorage()
        self.store = store
        self.worktreeId = worktreeId
        self.tabId = tabId
        self.lsp = lsp
        self.language = lsp?.language(forFileExtension: (relativePath as NSString).pathExtension)
        let delegate = BufferStorageDelegate { [weak self] in self?.handleEdit() }
        self.storageDelegate = delegate
        self.storage.delegate = delegate
        loadFromDisk()
        if restoreEnabled,
           let store, let worktreeId, let tabId,
           let snap = (try? store.read(worktreeId: worktreeId, tabId: tabId)) {
            applySnapshot(snap)
        }
        onEdit { [weak self] in self?.scheduleSnapshot() }
        if let lsp, let language {
            let url = worktreeRoot.appendingPathComponent(relativePath)
            let text = storage.string
            Task { await lsp.openDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: language, text: text) }
        }
    }

    @discardableResult
    func onEdit(_ block: @escaping () -> Void) -> EditObserverToken {
        let id = UUID()
        editObservers[id] = block
        return EditObserverToken(id: id)
    }

    func removeOnEdit(_ token: EditObserverToken) {
        editObservers.removeValue(forKey: token.id)
    }

    private func handleEdit() {
        guard !loading else { return }
        editGeneration &+= 1
        let snapshot = Array(editObservers.values)
        for block in snapshot { block() }
    }

    func revert() {
        loadFromDisk()
        discardSnapshot()
        handleEdit()
    }

    func startWatching() {
        stopWatching()
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

    func stopWatching() {
        watcherSource?.cancel()
        watcherSource = nil
        watcherFD = -1
    }

    private func handleWatcherEvent() {
        let url = worktreeRoot.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            if dirty {
                conflict = .deletedOnDisk
            }
            // If the buffer is clean and the file vanished, leave the buffer
            // contents in place. The next ⌘S will hit `save()`'s
            // moveItem-when-target-missing branch and recreate the file.
            // No conflict raised — we have nothing to lose.
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

    func resolveConflictKeepingMine() {
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
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let canonical = storage.string
        try write(canonical: canonical, to: url, createDirectories: false)
        originalText = canonical
        updateOriginalMtime(from: url)
        startWatching()
        discardSnapshot()
        notifyDidSave(url: url)
    }

    func saveAs(relativePath newRelativePath: String) throws {
        lastSaveError = nil
        guard !readOnly else { return }
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let oldLanguage = language
        let canonical = storage.string
        stopWatching()
        do {
            try write(canonical: canonical, to: newURL, createDirectories: true)
            relativePath = newRelativePath
            language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
            originalText = canonical
            updateOriginalMtime(from: newURL)
            discardSnapshot()
            notifyDidClose(url: oldURL, language: oldLanguage)
            notifyDidOpen(url: newURL, text: canonical)
            notifyDidSave(url: newURL)
            startWatching()
        } catch {
            startWatching()
            throw error
        }
    }

    func moveTo(relativePath newRelativePath: String) throws {
        lastSaveError = nil
        guard !readOnly else { return }
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let oldLanguage = language
        stopWatching()
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
            if dirty {
                snapshotNow()
            } else {
                discardSnapshot()
            }
            notifyDidClose(url: oldURL, language: oldLanguage)
            notifyDidOpen(url: newURL, text: storage.string)
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

    private func renameItem(at oldURL: URL, to newURL: URL) throws {
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
    }

    private func notifyDidSave(url: URL) {
        if let lsp, let language {
            Task { await lsp.didSave(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: language) }
        }
    }

    private func notifyDidClose(url: URL, language: String?) {
        if let lsp, let language {
            Task { await lsp.closeDocument(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: language) }
        }
    }

    private func notifyDidOpen(url: URL, text: String) {
        if let lsp, let language {
            Task { await lsp.openDocument(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: language, text: text) }
        }
    }

    func saveRecordingError() throws {
        do {
            try save()
        } catch {
            lastSaveError = (error as NSError).localizedDescription
            throw error
        }
    }

    // MARK: - Snapshot / restore (hot-exit)

    private func applySnapshot(_ snap: EditorBufferStore.Snapshot) {
        loading = true
        defer { loading = false }
        storage.setAttributedString(NSAttributedString(string: snap.content))
        originalText = snap.originalText
        originalMtime = snap.originalMtime
        lineEnding = snap.lineEnding
        readOnly = false
    }

    private func scheduleSnapshot() {
        guard store != nil, worktreeId != nil, tabId != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.snapshotNow() }
        }
    }

    /// Writes an immediate snapshot if the buffer is dirty and hot-exit is
    /// enabled (store/worktreeId/tabId all set on the production init).
    /// Safe to call from any state — clean buffers discard stale snapshots,
    /// while buffers without a store remain a no-op.
    func snapshotNow() {
        guard let store, let worktreeId, let tabId else { return }
        guard dirty else {
            discardSnapshot()
            return
        }
        let snap = EditorBufferStore.Snapshot(
            relativePath: relativePath,
            content: storage.string,
            originalText: originalText,
            originalMtime: originalMtime,
            lineEnding: lineEnding
        )
        try? store.write(snap, worktreeId: worktreeId, tabId: tabId)
    }

    private func discardSnapshot() {
        guard let store, let worktreeId, let tabId else { return }
        store.discard(worktreeId: worktreeId, tabId: tabId)
    }

    /// Tear-down for a buffer. App quit paths can keep a final dirty snapshot
    /// for hot-exit restore; explicit tab removal discards it.
    func close(persistDirtySnapshot: Bool = true) {
        snapshotTask?.cancel()
        if persistDirtySnapshot {
            if dirty { snapshotNow() }
        } else {
            discardSnapshot()
        }
        stopWatching()
        if let lsp, let language {
            let url = worktreeRoot.appendingPathComponent(relativePath)
            Task { await lsp.closeDocument(worktreeRoot: self.worktreeRoot, fileURL: url, languageId: language) }
        }
    }

    /// Compares the snapshot's recorded original mtime to the current file's
    /// mtime. If they differ, the file changed while we were quit and the
    /// user's snapshot is "their version" against a moved baseline — show
    /// the conflict banner. Called on first display after restore.
    func checkForConflictOnRestore() {
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

    private func loadFromDisk() {
        loading = true
        defer { loading = false }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
            readOnly = true
            return
        }
        let detected = LineEnding.detect(in: raw)
        let canonical = LineEnding.lf.normalize(raw)
        storage.setAttributedString(NSAttributedString(string: canonical))
        originalText = canonical
        lineEnding = detected
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            originalMtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if let nsPerms = attrs[.posixPermissions] as? NSNumber {
                permissions = mode_t(nsPerms.uint16Value)
            }
        }
        readOnly = false
    }
}

private final class BufferStorageDelegate: NSObject, NSTextStorageDelegate {
    private let onDidProcess: () -> Void
    init(_ onDidProcess: @escaping () -> Void) {
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
        onDidProcess()
    }
}
