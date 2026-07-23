import Foundation

/// On-disk hot-exit snapshot store for dirty editor buffers. Snapshots live
/// at `<AppSupport>/Alas/buffers/<worktreeId>/<tabId>.json` and are written
/// on a debounce during typing, on tab close, and at app quit. They are
/// consumed at next launch when the matching tab is re-displayed.
@MainActor
final class EditorBufferStore {
    struct Snapshot: Codable, Equatable {
        var relativePath: String
        var content: String
        var originalText: String
        var originalMtime: Date
        var lineEnding: LineEnding
    }

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// External (out-of-worktree) buffer cache keyed by
    /// `(worktreeId, absolute path)`. Distinct from the in-worktree cache
    /// so absolute paths never collide with relative ones.
    private struct ExternalKey: Hashable {
        let worktreeId: String
        let path: String
    }

    private var externalBuffers: [ExternalKey: EditorBuffer] = [:]

    /// `rootOverride` is for tests only; production callers omit it and
    /// the store reads/writes under `Paths.buffersRoot`.
    init(rootOverride: URL? = nil) {
        self.root = rootOverride ?? Paths.buffersRoot
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let ti = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: ti)
        }
        self.decoder = dec
    }

    private func fileURL(worktreeId: String, tabId: String) -> URL {
        root.appendingPathComponent(worktreeId, isDirectory: true)
            .appendingPathComponent("\(tabId).json")
    }

    func write(_ snapshot: Snapshot, worktreeId: String, tabId: String) throws {
        let dir = root.appendingPathComponent(worktreeId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = fileURL(worktreeId: worktreeId, tabId: tabId)
        let data = try encoder.encode(snapshot)
        let tmp = file.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: file)
        }
    }

    func read(worktreeId: String, tabId: String) throws -> Snapshot? {
        let file = fileURL(worktreeId: worktreeId, tabId: tabId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return nil
        }
        do {
            return try decoder.decode(Snapshot.self, from: data)
        } catch {
            // Corruption: delete and treat as no-snapshot. We can't recover,
            // and leaving the broken file in place would mean every subsequent
            // launch tries (and fails) to restore it.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    func discard(worktreeId: String, tabId: String) {
        let file = fileURL(worktreeId: worktreeId, tabId: tabId)
        try? FileManager.default.removeItem(at: file)
    }

    func externalBuffer(worktreeId: String, absoluteURL: URL, editable: Bool = false) -> EditorBuffer {
        let key = ExternalKey(worktreeId: worktreeId, path: absoluteURL.path)
        if let cached = externalBuffers[key] {
            // Upgrade a previously read-only external buffer to an editable one
            // when an editable open is requested (e.g. a run-script edit reuses
            // a URL first opened via ⌘-click). Recreate so the buffer's
            // `externalEditable` flag and readOnly state match the request.
            if editable, !cached.externalEditable {
                discardExternalBuffer(worktreeId: worktreeId, absoluteURL: absoluteURL)
            } else {
                return cached
            }
        }
        let buffer = EditorBuffer(externalAbsoluteURL: absoluteURL, editable: editable)
        externalBuffers[key] = buffer
        return buffer
    }

    /// Non-creating lookup for an external buffer. Returns nil if no buffer
    /// has been created yet for this `(worktreeId, absoluteURL)` pair. Used
    /// by read-only checks (e.g. `EditorTabView.isBinary`) to avoid the
    /// side-effecting creation in `externalBuffer`.
    func peekExternalBuffer(worktreeId: String, absoluteURL: URL) -> EditorBuffer? {
        let key = ExternalKey(worktreeId: worktreeId, path: absoluteURL.path)
        return externalBuffers[key]
    }

    /// Remove an external buffer from the cache and stop its watcher.
    /// A no-op if no buffer for this URL exists in `worktreeId`.
    func discardExternalBuffer(worktreeId: String, absoluteURL: URL) {
        let key = ExternalKey(worktreeId: worktreeId, path: absoluteURL.path)
        guard let buffer = externalBuffers.removeValue(forKey: key) else { return }
        buffer.close(persistDirtySnapshot: false)
    }
}
