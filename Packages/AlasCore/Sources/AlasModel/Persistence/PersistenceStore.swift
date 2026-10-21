import Foundation
import AlasFoundation

public protocol PersistenceStoreProtocol {
    func write<T: Encodable>(_ value: T, to url: URL) throws
    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T?
    func readIfExistsReportingRecovery<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> PersistenceReadResult<T>
}

public struct PersistenceReadResult<Value> {
    public let value: Value?
    public let recoveryError: Error?

    public init(value: Value?, recoveryError: Error? = nil) {
        self.value = value
        self.recoveryError = recoveryError
    }
}

extension PersistenceStoreProtocol {
    public func readIfExistsReportingRecovery<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> PersistenceReadResult<T> {
        PersistenceReadResult(value: try readIfExists(type, from: url))
    }
}

public struct PersistenceStore: PersistenceStoreProtocol, Sendable {
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(data: encoder.encode(value), to: url)
    }

    /// Atomically replaces `url` with `data`, creating its directory.
    public func write(data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    public func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    public func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        try readIfExistsReportingRecovery(type, from: url).value
    }

    public func readIfExistsReportingRecovery<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> PersistenceReadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistenceReadResult(value: nil)
        }
        do {
            return PersistenceReadResult(value: try read(T.self, from: url))
        } catch {
            try moveBroken(url)
            return PersistenceReadResult(value: nil, recoveryError: error)
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
