import Foundation
import Testing
@testable import Alas

struct AlasCLIRequestTests {
    @Test func decodeOpenRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt","/tmp/b.txt"]}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request.version == 1)
        #expect(request.command == .open)
        #expect(request.sessionId == "s1")
        #expect(request.paths == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test func rejectsNonCLIKind() throws {
        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1"}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func rejectsEmptyPathsForOpen() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":[]}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func responseEncodesOKAndError() throws {
        let ok = String(data: try AlasCLIResponse.ok.encode(), encoding: .utf8) ?? ""
        let error = String(data: try AlasCLIResponse.error("No file.").encode(), encoding: .utf8) ?? ""

        #expect(ok.contains(#""ok":true"#) || ok.contains(#""ok": true"#))
        #expect(error.contains(#""ok":false"#) || error.contains(#""ok": false"#))
        #expect(error.contains("No file."))
    }
}
