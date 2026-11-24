import Foundation
@testable import AlasCore

/// A persistence store that keeps every file in memory, so a test can read
/// what a service saved or hand a second instance the same files.
final class MemoryStore: PersistenceStoreProtocol {
    var files: [URL: Data] = [:]

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        files[url] = try JSONEncoder().encode(value)
    }

    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = files[url] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
