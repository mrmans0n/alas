import Foundation
@testable import Alas

/// A `PersistenceStoreProtocol` for tests. Reads return the value seeded for
/// the requested type, or nil; writes are recorded but never read back, so a
/// test sees exactly what it seeded. `writeError`, when set, fails every write.
final class TestPersistenceStore: PersistenceStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var seeded: [ObjectIdentifier: Any] = [:]
    private var recorded: [(value: Any, url: URL)] = []
    private var failure: Error?

    init(_ seeds: Any..., writeError: Error? = nil) {
        failure = writeError
        for seed in seeds {
            seeded[ObjectIdentifier(type(of: seed))] = seed
        }
    }

    /// Thrown by every write while set.
    var writeError: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    /// Every successful write, in order.
    var writes: [(value: Any, url: URL)] { lock.withLock { recorded } }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try lock.withLock {
            if let failure { throw failure }
            recorded.append((value, url))
        }
    }

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
        lock.withLock { seeded[ObjectIdentifier(T.self)] as? T }
    }
}
