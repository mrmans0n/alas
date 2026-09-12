import Foundation
import Testing
@testable import Alas

struct WebPreviewCommandTests {
    @Test func typePreservesWhitespaceAndEmptyReplacement() throws {
        for text in ["  hello\n", ""] {
            let data = try JSONSerialization.data(withJSONObject: [
                "v": 1, "kind": "cli", "session_id": "caller", "command": "preview_type",
                "params": ["preview_id": "p", "element_id": "e", "text": text],
            ])
            let request = try AlasCLIRequest.decode(from: data)
            guard case .preview(let command) = request.command else { Issue.record("Expected preview command")
            return }
            #expect(command.text == text)
        }
    }

    @Test(arguments: [
        (#"preview_click"#, #"{"preview_id":"p"}"#),
        (#"preview_wait"#, #"{"preview_id":"p","timeout_ms":20001}"#),
        (#"preview_inspect"#, #"{"preview_id":"p","limit":101}"#),
        (#"preview_capture"#, #"{"preview_id":"p","region":{"x":0,"y":0,"width":-1,"height":1}}"#),
        (#"preview_capture"#, #"{"preview_id":"p","element_id":"e","region":{"x":0,"y":0,"width":1,"height":1}}"#),
        (#"preview_open"#, #"{"url":"https://example.com","script_key":"dev"}"#),
        (#"preview_navigate"#, #"{"preview_id":"p","url":"file:///etc/passwd"}"#),
        (#"preview_scroll"#, #"{"preview_id":"p","x":100001}"#),
        (#"preview_console"#, #"{"preview_id":"p","clear":"true"}"#),
        (#"preview_wait"#, #"{"preview_id":"p","condition":"visible"}"#),
        (#"preview_reload"#, #"{}"#),
    ])
    func rejectsInvalidRequests(command: String, params: String) {
        let json = "{\"v\":1,\"kind\":\"cli\",\"session_id\":\"caller\",\"command\":\"\(command)\",\"params\":\(params)}"
        #expect(throws: AlasCLIRequestError.self) { try AlasCLIRequest.decode(from: Data(json.utf8)) }
    }

    @Test func defaultsAreBoundedAndListNeedsNoParams() throws {
        let json = #"{"v":1,"kind":"cli","session_id":"caller","command":"preview_list"}"#
        guard case .preview(let command) = try AlasCLIRequest.decode(from: Data(json.utf8)).command else {
            Issue.record("Expected preview list")
            return
        }
        #expect(command.action == .list)
        #expect(command.limit == 50)
        #expect(command.timeoutMS == 5000)
    }
}
