import Foundation

protocol PersistenceStoreProtocol {
    func write<T: Encodable>(_ value: T, to url: URL) throws
    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T?
}

struct PersistenceStore: PersistenceStoreProtocol {
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Paths.ensureDirectoryExists(url.deletingLastPathComponent())
        let data = try encoder.encode(value)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try read(T.self, from: url)
        } catch {
            try moveBroken(url)
            return nil
        }
    }

    private func moveBroken(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).broken-\(stamp)")
        try FileManager.default.moveItem(at: url, to: dest)
    }
}
