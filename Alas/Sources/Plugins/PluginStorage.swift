import Foundation

/// A plugin's private key-value store for one project, persisted as one JSON file.
///
/// Values are arbitrary JSON kept as raw bytes. The file is assembled by splicing each value's
/// bytes into the object text, and read back with a small top-level scanner, so numbers such as
/// `1.0` or large integers are never re-typed by a `JSONSerialization` round trip.
@MainActor
final class PluginStorage {
    static let maxKeyBytes = 128
    static let maxTotalBytes = 1 << 20

    enum SetResult: Equatable { case stored, invalidKey, invalidValue, full }

    private let file: URL
    private var entries: [String: Data]?

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

    func get(_ key: String) -> Data? {
        load()[key]
    }

    func set(_ key: String, value: Data?) -> SetResult {
        let keyBytes = key.utf8.count
        guard (1...Self.maxKeyBytes).contains(keyBytes) else { return .invalidKey }
        var next = load()
        if let value {
            guard (try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)) != nil else {
                return .invalidValue
            }
            next[key] = value
        } else {
            next[key] = nil
        }
        guard next.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= Self.maxTotalBytes else {
            return .full
        }
        guard write(next) else { return .full }
        entries = next
        return .stored
    }

    func keys() -> [String] {
        load().keys.sorted()
    }

    // MARK: - Persistence

    private func load() -> [String: Data] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: file)).flatMap(Self.parse) ?? [:]
        entries = loaded
        return loaded
    }

    private func write(_ entries: [String: Data]) -> Bool {
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
    private static func parse(_ data: Data) -> [String: Data]? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
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
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
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
                case UInt8(ascii: "\""): skipString(); continue
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
        return result
    }
}
