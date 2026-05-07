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
    let relativePath: String

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

    struct EditObserverToken { fileprivate let id: UUID }

    /// `true` while the in-memory text differs from the bytes last read
    /// from / written to disk. Computed from `storage.string` against
    /// `originalText` (cheap for files under ~1 MB).
    var dirty: Bool {
        guard !readOnly else { return false }
        return storage.string != originalText
    }

    init(worktreeRoot: URL, relativePath: String) {
        self.worktreeRoot = worktreeRoot
        self.relativePath = relativePath
        self.storage = NSTextStorage()
        let delegate = BufferStorageDelegate { [weak self] in self?.handleEdit() }
        self.storageDelegate = delegate
        self.storage.delegate = delegate
        loadFromDisk()
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
        let snapshot = Array(editObservers.values)
        for block in snapshot { block() }
    }

    func revert() {
        loadFromDisk()
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
            // contents in place but clear original-text bookkeeping so the
            // next save recreates the file. Don't raise a conflict — we have
            // nothing to lose.
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
        guard !readOnly else { return }
        let url = worktreeRoot.appendingPathComponent(relativePath)
        let canonical = storage.string
        let onDisk = lineEnding.normalize(canonical)
        let dir = url.deletingLastPathComponent()
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

        originalText = canonical
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            originalMtime = mtime
        }
        startWatching()
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
