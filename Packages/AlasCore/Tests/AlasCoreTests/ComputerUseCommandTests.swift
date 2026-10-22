import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct ComputerUseCommandTests {
    private func decode(_ command: String, _ params: String?) throws -> AlasCLIRequest {
        let tail = params.map { ",\"params\":\($0)" } ?? ""
        let json = "{\"v\":1,\"kind\":\"cli\",\"session_id\":\"s\",\"command\":\"\(command)\"\(tail)}"
        return try AlasCLIRequest.decode(from: Data(json.utf8))
    }

    @Test func decodesEachActionWithDefaults() throws {
        let inspect = try decode("computer_inspect", #"{"window_id":42}"#)
        #expect(inspect.command == .computer(.init(action: .inspect, windowID: 42, query: nil, limit: 300, maxDepth: 12)))
        let apps = try decode("computer_apps", nil)
        #expect(apps.command == .computer(.init(action: .apps, windowID: nil, query: nil, limit: 300, maxDepth: 12)))
        let shot = try decode("computer_screenshot", #"{"window_id":7}"#)
        #expect(shot.command == .computer(.init(action: .screenshot, windowID: 7)))
    }

    @Test(arguments: [
        ("computer_screenshot", "{}"),
        ("computer_inspect", #"{"window_id":1,"limit":0}"#),
        ("computer_inspect", #"{"window_id":1,"limit":3001}"#),
        ("computer_inspect", #"{"window_id":1,"max_depth":13}"#),
        ("computer_inspect", #"{"window_id":1,"query":"   "}"#),
        ("computer_inspect", "{\"window_id\":1,\"query\":\"\(String(repeating: "x", count: 257))\"}"),
        ("computer_apps", #"{"window_id":1}"#),
        ("computer_click", #"{"window_id":1}"#),
    ])
    func rejectsInvalidRequests(command: String, params: String) {
        #expect(throws: AlasCLIRequestError.self) { try decode(command, params) }
    }
}
