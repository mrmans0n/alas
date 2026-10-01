import Foundation

/// A plugin's private key-value store for one project, persisted as one JSON file.
///
/// Values are arbitrary JSON kept as raw bytes. The file is assembled by splicing each value's
/// bytes into the object text, and read back with a small top-level scanner, so numbers such as
/// `1.0` or large integers are never re-typed by a `JSONSerialization` round trip.
///
/// Reads and writes see memory at once; the file is written off the main actor, one write at a
/// time and always the latest entries, so a burst of sets costs at most two writes.
@MainActor
final class PluginStorage {
    static let maxKeyBytes = 128
    static let maxTotalBytes = 1 << 20

    enum SetResult: Equatable { case stored, invalidKey, invalidValue, full, failed }

    private let file: URL
    private var entries: [String: Data]?
    /// Bumped by every change; `written` is the version last on disk.
    private var version = 0
    private var written = 0
    private var writing: Task<Bool, Never>?

    init(file: URL) {
        self.file = file
    }

    /// `root/PluginData/<pluginID>/<projectID>.json`, with the project id percent-encoded so it
    /// can never escape the plugin's folder.
    static func file(pluginID: String, projectID: String, root: URL = Paths.appSupportRoot) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var name = projectID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "project"
        // "." and ".." survive encoding; neutralise them.
        if name.isEmpty || name.allSatisfy({ $0 == "." }) {
            name = name.replacingOccurrences(of: ".", with: "%2E")
        }
        return root.appending(path: "PluginData").appending(path: pluginID).appending(path: name + ".json")
    }

    static func isValidKey(_ key: String) -> Bool {
        (1...maxKeyBytes).contains(key.utf8.count)
    }

    func get(_ key: String) -> Data? {
        load()?[key]
    }

    /// Returns once the change is on disk, or `.failed` when it could not be written. A failed change
    /// stays in memory and goes out with the next write.
    func set(_ key: String, value: Data?) async -> SetResult {
        guard Self.isValidKey(key) else { return .invalidKey }
        guard var next = load() else { return .failed }
        if let value {
            // Foundation also accepts UTF-16/32 and a BOM, which would corrupt the UTF-8 file.
            guard String(data: value, encoding: .utf8) != nil,
                  !value.starts(with: [0xEF, 0xBB, 0xBF]),
                  (try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)) != nil
            else {
                return .invalidValue
            }
            next[key] = value
        } else {
            next[key] = nil
        }
        guard next.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= Self.maxTotalBytes else {
            return .full
        }
        entries = next
        version += 1
        return await flush() ? .stored : .failed
    }

    /// Writes until the file holds this caller's change, waiting out any write already running.
    private func flush() async -> Bool {
        let target = version
        while written < target {
            if let writing {
                _ = await writing.value
                continue
            }
            // The task updates `writing` and `written` itself, so a waiter that resumes after it
            // always sees the finished state instead of spinning on a completed task.
            let task = Task { @MainActor [file] () -> Bool in
                let snapshot = entries ?? [:]
                let version = version
                let ok = await Task.detached { Self.write(snapshot, to: file) }.value
                writing = nil
                if ok { written = max(written, version) }
                return ok
            }
            writing = task
            guard await task.value else { return false }
        }
        return true
    }

    /// False when the file is unreadable and could not be moved aside: reads would wrongly look empty.
    var isAvailable: Bool {
        load() != nil
    }

    func keys() -> [String] {
        (load() ?? [:]).keys.sorted()
    }

    // MARK: - Persistence

    /// nil when an unreadable file could not be moved aside; the store is then unavailable.
    private func load() -> [String: Data]? {
        if let entries { return entries }
        var loaded: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            if let parsed = (try? Data(contentsOf: file)).flatMap(Self.parse) {
                loaded = parsed
            } else {
                // Never overwrite user data: move the unreadable file aside first.
                // ponytail: only the latest .corrupt is kept.
                let aside = file.appendingPathExtension("corrupt")
                do {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: aside.path, isDirectory: &isDirectory) {
                        // Only ever replace an older backup file, never a directory.
                        if isDirectory.boolValue { return nil }
                        _ = try FileManager.default.replaceItemAt(aside, withItemAt: file)
                    } else {
                        try FileManager.default.moveItem(at: file, to: aside)
                    }
                } catch {
                    return nil
                }
            }
        }
        entries = loaded
        return loaded
    }

    private nonisolated static func write(_ entries: [String: Data], to file: URL) -> Bool {
        var out = Data("{".utf8)
        for (index, key) in entries.keys.sorted().enumerated() {
            guard let keyJSON = try? JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed) else {
                return false
            }
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(keyJSON)
            out.append(UInt8(ascii: ":"))
            out.append(entries[key]!)
        }
        out.append(UInt8(ascii: "}"))
        guard parse(out) != nil else { return false }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Splits a top-level JSON object into key -> raw value bytes; nil when malformed.
    private nonisolated static func parse(_ data: Data) -> [String: Data]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        /// Advances past one string literal starting at `i` (an opening quote).
        func skipString() {
            i += 1
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
            i += 1
        }
        var result: [String: Data] = [:]
        skipSpace()
        i += 1  // "{"
        while true {
            skipSpace()
            if i >= bytes.count || bytes[i] == UInt8(ascii: "}") { break }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            let keyStart = i
            skipString()
            guard i <= bytes.count,
                  let key = try? JSONSerialization.jsonObject(
                      with: Data(bytes[keyStart..<i]), options: .fragmentsAllowed) as? String
            else { return nil }
            skipSpace()
            i += 1  // ":"
            skipSpace()
            let valueStart = i
            var depth = 0
            scan: while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    skipString()
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { break scan }
                    depth -= 1
                case UInt8(ascii: ","): if depth == 0 { break scan }
                default: break
                }
                i += 1
            }
            var end = i
            while end > valueStart, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[end - 1]) { end -= 1 }
            result[key] = Data(bytes[valueStart..<end])
        }
        // A scanner/Foundation disagreement fails loudly instead of losing keys.
        return Set(result.keys) == Set(object.keys) ? result : nil
    }
}
