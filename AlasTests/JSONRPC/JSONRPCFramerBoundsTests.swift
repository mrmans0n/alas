import Foundation
import Testing
@testable import Alas

struct JSONRPCFramerBoundsTests {
    @Test func rejectsOversizedDeclarationBeforeReceivingBody() {
        var framer = JSONRPCFramer()
        framer.append(Data("Content-Length: 16777217\r\n\r\n".utf8))
        #expect(framer.drainFrames().isEmpty)
        #expect(framer.hasFailed)
        framer.append(JSONRPCFramer.encode(Data("{}".utf8)))
        #expect(framer.drainFrames().isEmpty)
    }

    @Test func rejectsOversizedBody() {
        var framer = JSONRPCFramer()
        let body = Data(repeating: 32, count: 16 * 1024 * 1024 + 1)
        framer.append(JSONRPCFramer.encode(body))
        #expect(framer.drainFrames().isEmpty)
    }

    @Test func rejectsOversizedHeader() {
        var framer = JSONRPCFramer()
        let header = "Extra: " + String(repeating: "x", count: 8192) + "\r\nContent-Length: 2\r\n\r\n{}"
        framer.append(Data(header.utf8))
        #expect(framer.drainFrames().isEmpty)
    }
}
