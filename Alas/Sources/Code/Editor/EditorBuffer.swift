import AppKit
import Foundation
import Observation

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
    let worktreeRoot: URL
    private(set) var relativePath: String

    /// `true` when this buffer represents a file outside the worktree (e.g.
    /// a dependency or system header opened via cmd-click). External buffers
    /// are read-only, never emit `didChange` to LSP, and never write back to
    /// disk — but they still reload when the file changes on disk.
    let isExternal: Bool

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
    private var editObservers: [UUID: (EditorTextEdit?) -> Void] = [:]
    @ObservationIgnored
    private var storageDelegate: BufferStorageDelegate = .init { _ in }
    @ObservationIgnored
    private var loading = false
    @ObservationIgnored
    private var watcherSource: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var watcherFD: Int32 = -1
    @ObservationIgnored
    private static let watchQueue = DispatchQueue(label: "alas.editor.buffer.watch", qos: .utility)
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
    @ObservationIgnored
    var shouldFollowPathChange: ((String, String) -> Bool)?
    @ObservationIgnored
    var onPathChanged: ((String, String) -> Void)?
    @ObservationIgnored
    var onSnapshotRequested: (() -> Void)?
    @ObservationIgnored
    var onDiscardSnapshotsRequested: (() -> Void)?
    var persistenceTabId: String? { tabId }

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
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: nil)
    }

    /// Production initializer that opts into hot-exit and opens an LSP
    /// document. The buffer owns the LSP open/close lifecycle for this file.
    convenience init(worktreeRoot: URL, relativePath: String, store: EditorBufferStore, worktreeId: String, tabId: String, lsp: WorkspaceLSPManager) {
        self.init(worktreeRoot: worktreeRoot, relativePath: relativePath, isExternal: false, store: store, worktreeId: worktreeId, tabId: tabId, restoreEnabled: true, lsp: lsp)
    }

    /// External-mode init: loads `absoluteURL` synchronously, marks the buffer
    /// read-only, and skips all save/didChange/file-watcher write paths. The
    /// buffer still re-loads contents when the file changes on disk (passive
    /// reload only — it never writes back). Uses sentinel worktreeRoot/
    /// relativePath values (directory + filename) so the rest of the buffer
    /// machinery works without optional-unwrap proliferation (option B).
    convenience init(externalAbsoluteURL: URL) {
        let worktreeRoot = externalAbsoluteURL.deletingLastPathComponent()
        let relativePath = externalAbsoluteURL.lastPathComponent
        self.init(
            worktreeRoot: worktreeRoot,
            relativePath: relativePath,
            isExternal: true,
            store: nil,
            worktreeId: nil,
            tabId: nil,
            restoreEnabled: false,
            lsp: nil
        )
    }

    private init(worktreeRoot: URL, relativePath: String, isExternal: Bool, store: EditorBufferStore?, worktreeId: String?, tabId: String?, restoreEnabled: Bool, lsp: WorkspaceLSPManager?) {
        self.worktreeRoot = worktreeRoot
        self.relativePath = relativePath
        self.isExternal = isExternal
        self.storage = NSTextStorage()
        self.store = store
        self.worktreeId = worktreeId
        self.tabId = tabId
        self.lsp = lsp
        self.language = lsp?.language(forFileExtension: (relativePath as NSString).pathExtension)
        let delegate = BufferStorageDelegate { [weak self] edit in self?.handleEdit(edit: edit) }
        self.storageDelegate = delegate
        self.storage.delegate = delegate
        loadFromDisk()
        if !isExternal,
           restoreEnabled,
           let store, let worktreeId, let tabId,
           let snap = (try? store.read(worktreeId: worktreeId, tabId: tabId)) {
            applySnapshot(snap)
        }
        onEdit { [weak self] in self?.scheduleSnapshot() }
        if !isExternal, let lsp, let language {
            let url = worktreeRoot.appendingPathComponent(relativePath)
            let text = storage.string
            Task { await lsp.openDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: language, text: text) }
        }
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
        guard !isExternal, let lsp, let language else { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        guard !lsp.isDocumentOpen(fileURL: url, worktreeRoot: worktreeRoot) else { return }
        let text = storage.string
        Task { await lsp.openDocument(worktreeRoot: worktreeRoot, fileURL: url, languageId: language, text: text) }
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

    private func handleEdit(edit: EditorTextEdit?) {
        guard !loading else { return }
        // External buffers are read-only; suppress all observer notifications
        // so didChange is never propagated to LSP or snapshot scheduler.
        guard !isExternal else { return }
        editGeneration &+= 1
        let snapshot = Array(editObservers.values)
        for block in snapshot { block(edit) }
    }

    func revert() {
        loadFromDisk()
        discardSnapshot()
        handleEdit(edit: nil)
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
            if let movedPath = findMovedRelativePath() {
                followMovedFile(to: movedPath)
                return
            }
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

    private func followMovedFile(to newRelativePath: String) {
        let oldURL = worktreeRoot.appendingPathComponent(relativePath)
        let oldRelativePath = relativePath
        let newURL = worktreeRoot.appendingPathComponent(newRelativePath)
        let oldLanguage = language
        let wasDirty = dirty
        guard shouldFollowPathChange?(oldRelativePath, newRelativePath) ?? true else {
            if wasDirty {
                conflict = .deletedOnDisk
            }
            return
        }
        stopWatching()
        relativePath = newRelativePath
        language = lsp?.language(forFileExtension: (newRelativePath as NSString).pathExtension)
        if wasDirty {
            updateOriginalFileIdentity(from: newURL)
            conflict = movedFileDiffersFromOriginal(at: newURL) ? .changedOnDisk : nil
            snapshotNow()
        } else {
            loadFromDisk()
            discardSnapshot()
            handleEdit(edit: nil)
        }
        notifyDidClose(url: oldURL, language: oldLanguage)
        notifyDidOpen(url: newURL, text: storage.string)
        onPathChanged?(oldRelativePath, newRelativePath)
        startWatching()
    }

    private func movedFileDiffersFromOriginal(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return true }
        if mtime != originalMtime { return true }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return LineEnding.lf.normalize(raw) != originalText
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
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
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
            updateOriginalFileIdentity(from: newURL)
            discardSnapshot()
            notifyDidClose(url: oldURL, language: oldLanguage)
            notifyDidOpen(url: newURL, text: canonical)
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
        guard shouldFollowPathChange?(relativePath, newRelativePath) ?? true else {
            throw CocoaError(.fileWriteFileExists)
        }
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
            updateOriginalFileIdentity(from: newURL)
            if dirty {
                snapshotNow()
            } else {
                discardSnapshot()
            }
            notifyDidClose(url: oldURL, language: oldLanguage)
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

    private func findMovedRelativePath() -> String? {
        guard let originalFileIdentifier, let originalVolumeIdentifier else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(
            at: worktreeRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return nil }

        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let file = values.fileResourceIdentifier,
                  let volume = values.volumeIdentifier,
                  (file as AnyObject).isEqual(originalFileIdentifier),
                  (volume as AnyObject).isEqual(originalVolumeIdentifier) else { continue }
            return relativePath(for: candidate)
        }
        return nil
    }

    private func relativePath(for url: URL) -> String? {
        let root = worktreeRoot.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    private func oldURLRelativePath(from url: URL) -> String {
        relativePath(for: url) ?? relativePath
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
            try save()
            return
        }
        guard config.formatOnSave, let lsp else {
            try save()
            return
        }
        let resolvedLanguage = language ?? lsp.language(forFileExtension: ((relativePath as NSString).pathExtension))
        guard let resolvedLanguage else {
            try save()
            return
        }
        let generation = editGeneration
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let text = storage.string
        await lsp.didChange(worktreeRoot: worktreeRoot, fileURL: url, languageId: resolvedLanguage, text: text, edits: nil)
        let options = LSPFormattingOptions(tabSize: 4, insertSpaces: true)
        let edits: [LSPTextEdit]? = await requestFormatting(lsp: lsp, url: url, language: resolvedLanguage, options: options, timeoutNanoseconds: formattingTimeoutNanoseconds)
        guard editGeneration == generation else {
            try save()
            return
        }
        guard let edits, !edits.isEmpty else {
            try save()
            return
        }
        guard applyFormattingEdits(edits) else {
            try save()
            return
        }
        let formattedText = storage.string
        await lsp.didChange(worktreeRoot: worktreeRoot, fileURL: url, languageId: resolvedLanguage, text: formattedText, edits: nil)
        try save()
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
        loading = true
        storage.beginEditing()
        for edit in ascending.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.newText)
        }
        storage.endEditing()
        loading = false
        editGeneration &+= 1
        return true
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
            readOnly = true
            return
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            storage.setAttributedString(NSAttributedString(string: "(read-only: file is not valid UTF-8)"))
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
        updateOriginalFileIdentity(from: url)
        // External buffers remain read-only even after a successful reload;
        // the isExternal flag is the authoritative source of read-only-ness.
        readOnly = isExternal ? true : false
    }
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
