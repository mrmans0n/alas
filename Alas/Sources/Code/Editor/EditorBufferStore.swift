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
}
