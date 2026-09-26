import Foundation
import Testing
@testable import Alas

@Suite("ACP child blocker")
struct ACPChildBlockerTests {
    @Test("request keys are stable and never collide across id shapes")
    func requestKeysAreDistinct() {
        #expect(ACPChildBlocker.requestKey(JSONRPCID.number(7)) == "n7")
        #expect(ACPChildBlocker.requestKey(JSONRPCID.string("7")) == "s7")
        // A numeric 7 and the string "7" are different requests and must not
        // share an outcome id.
        #expect(
            ACPChildBlocker.requestKey(JSONRPCID.number(7))
                != ACPChildBlocker.requestKey(JSONRPCID.string("7"))
        )
        let uuid = UUID()
        #expect(ACPChildBlocker.requestKey(uuid) == "u\(uuid.uuidString)")
    }
}
