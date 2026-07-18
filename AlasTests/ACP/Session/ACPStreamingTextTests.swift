import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPStreamingText")
struct ACPStreamingTextTests {
    @Test("append concatenates and exposes the latest value")
    func appendsAndExposes() async {
        let t = StreamingText("a")
        t.append("b")
        t.append("c")
        #expect(t.value == "abc")
    }

    @Test("append tracks byte length, revision, and latest suffix")
    func appendTracksStreamingMetadata() async {
        let t = StreamingText("a")

        t.append("é")

        #expect(t.value == "aé")
        #expect(t.utf8Length == 3)
        #expect(t.revision == 1)
        #expect(t.lastAppendedSuffix == "é")
    }

    @Test("two ACPMessage.agent values backed by the same buffer compare equal")
    func identityEqualityForSharedBuffer() async {
        let buf = StreamingText("hi")
        let id = UUID()
        let lhs = ACPMessage.agent(id: id, buf)
        let rhs = ACPMessage.agent(id: id, buf)
        #expect(lhs == rhs)
    }

    @Test("two ACPMessage.agent values with different buffers do NOT compare equal")
    func differentBuffersAreUnequal() async {
        let id = UUID()
        let lhs = ACPMessage.agent(id: id, StreamingText("hi"))
        let rhs = ACPMessage.agent(id: id, StreamingText("hi"))
        #expect(lhs != rhs)
    }

    @Test("a synchronous burst of chunks coalesces into a single publish")
    func synchronousBurstCoalescesPublishes() async {
        let t = StreamingText()

        // A tight loop appends far faster than the throttle interval, so
        // every chunk lands inside one window: the first publishes
        // immediately, the second schedules a trailing drain, and the
        // rest are dropped until that drain fires.
        for _ in 0..<200 {
            t.append("x")
        }

        #expect(t.value.count == 200)
        #expect(t.revision == 200)
        #expect(t.publishCountForTests == 1)
    }

    @Test("the trailing chunk of a burst is eventually delivered")
    func trailingChunkDeliveredAfterDrain() async throws {
        let t = StreamingText()

        t.append("a")
        t.append("b")
        // Only the first append published synchronously; the second is
        // pending on the trailing-edge drain.
        #expect(t.publishCountForTests == 1)

        try await Task.sleep(nanoseconds: 120_000_000)

        // The drain fired, delivering a publish for the coalesced tail.
        #expect(t.publishCountForTests == 2)
        #expect(t.value == "ab")
    }
}
