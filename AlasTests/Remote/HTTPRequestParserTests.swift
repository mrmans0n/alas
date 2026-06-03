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

    @Test func returnsNilUntilHeadersComplete() throws {
        var buffer = Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)  // no terminating blank line yet
        #expect(try HTTPRequestParser.parse(&buffer) == nil)
        #expect(!buffer.isEmpty)
    }

    @Test func parsesQueryString() throws {
        var buffer = Data("GET /?code=ABC123 HTTP/1.1\r\n\r\n".utf8)
        let req = try HTTPRequestParser.parse(&buffer)
        #expect(req?.path == "/")
        #expect(req?.query["code"] == "ABC123")
    }
}
