import Foundation
@testable import AlasCore

extension AttentionStore {
    /// An empty attention log for a test's core context. The default reads
    /// the developer's real profile, which can hold megabytes of events,
    /// decoded on the main actor for every context and stalling every other
    /// main-actor test meanwhile.
    static func scratch() -> AttentionStore {
        AttentionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("alas-attention-\(UUID().uuidString).json"))
    }
}
