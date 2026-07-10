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
}
