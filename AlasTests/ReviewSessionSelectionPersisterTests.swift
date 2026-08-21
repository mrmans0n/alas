import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewSessionSelectionPersisterTests {
    @Test func coalescesBurstIntoSingleLatestWrite() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("first") }
        persister.schedule { writes.append("second") }
        persister.schedule { writes.append("third") }
        #expect(writes.isEmpty)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["third"])
    }

    @Test func flushRunsPendingWriteImmediatelyAndOnlyOnce() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("pending") }
        persister.flush()
        #expect(writes == ["pending"])

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["pending"])
    }

    @Test func flushWithoutPendingWriteIsNoOp() {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        persister.flush()
    }

    @Test func scheduleAfterFlushStartsFreshDebounce() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("first") }
        persister.flush()
        persister.schedule { writes.append("second") }
        #expect(writes == ["first"])

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["first", "second"])
    }
}
