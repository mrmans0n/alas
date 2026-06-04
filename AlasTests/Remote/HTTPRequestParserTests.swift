import Testing
import Foundation
@testable import Alas

struct HTTPRequestParserTests {
    @Test func parsesGetWithHeaders() throws {
        let raw = "GET /app.js HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\n\r\n"
        var buffer = Data(raw.utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.method == "GET")
        #expect(req?.path == "/app.js")
        #expect(req?.headers["upgrade"] == "websocket")
        #expect(req?.headers["sec-websocket-key"] == "abc")
        #expect(buffer.isEmpty)
    }

    @Test func returnsNilUntilHeadersCompleteLeavingBufferUnchanged() throws {
        let original = "GET / HTTP/1.1\r\nHost: x\r\n"  // no terminating blank line yet
        var buffer = Data(original.utf8)
        #expect(try HTTPRequestParser.parse(&buffer) == nil)
        #expect(buffer == Data(original.utf8))  // buffer left untouched
    }

    @Test func parsesQueryString() throws {
        var buffer = Data("GET /?code=ABC123 HTTP/1.1\r\n\r\n".utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.path == "/")
        #expect(req?.query["code"] == "ABC123")
    }

    @Test func parsesMultipleQueryParams() throws {
        var buffer = Data("GET /?a=1&b=2&token=xy%3Dz HTTP/1.1\r\n\r\n".utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.query["a"] == "1")
        #expect(req?.query["b"] == "2")
        #expect(req?.query["token"] == "xy=z")  // percent-decoded value
    }

    @Test func headerValueMayContainColon() throws {
        var buffer = Data("GET / HTTP/1.1\r\nHost: localhost:4020\r\n\r\n".utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.headers["host"] == "localhost:4020")  // only the first colon splits
    }

    @Test func skipsHeaderLineWithoutColon() throws {
        var buffer = Data("GET / HTTP/1.1\r\ngarbage-no-colon\r\nHost: x\r\n\r\n".utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.headers["host"] == "x")           // valid header still parsed
        #expect(req?.headers.count == 1)               // colon-free line skipped, not crashed
    }

    @Test func throwsOnNonUTF8Headers() {
        var buffer = Data([0x47, 0xFF, 0xFE]) + Data("\r\n\r\n".utf8)  // 0xFF 0xFE invalid UTF-8
        #expect(throws: RemoteServerError.self) { _ = try HTTPRequestParser.parse(&buffer) }
    }
}
