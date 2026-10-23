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
        let deep = try decode("computer_inspect", #"{"window_id":42,"max_depth":32}"#)
        #expect(deep.command == .computer(.init(action: .inspect, windowID: 42, query: nil, limit: 300, maxDepth: 32)))
        let apps = try decode("computer_apps", nil)
        #expect(apps.command == .computer(.init(action: .apps, windowID: nil, query: nil, limit: 300, maxDepth: 12)))
        let shot = try decode("computer_screenshot", #"{"window_id":7}"#)
        #expect(shot.command == .computer(.init(action: .screenshot, windowID: 7)))
        let tagged = try decode("computer_screenshot", #"{"window_id":7,"call_id":"42-1"}"#)
        #expect(tagged.command == .computer(.init(action: .screenshot, windowID: 7, callID: "42-1")))
        let cancel = try decode("computer_cancel", #"{"call_id":"42-1"}"#)
        #expect(cancel.command == .computer(.init(action: .cancel, callID: "42-1")))
        let click = try decode("computer_click", #"{"window_id":3,"x":10.5,"y":20}"#)
        #expect(click.command == .computer(.init(action: .click, windowID: 3, limit: 100, x: 10.5, y: 20)))
        let rightClick = try decode(
            "computer_click",
            #"{"window_id":3,"ref":"e12","button":"right","count":2,"delivery":"direct","query":"ok","limit":3000,"include_screenshot":true}"#
        )
        #expect(rightClick.command == .computer(.init(
            action: .click, windowID: 3, query: "ok", limit: 3000, ref: "e12", button: .right, count: 2,
            delivery: .direct, includeScreenshot: true
        )))
        let type = try decode("computer_type", #"{"window_id":3,"text":"hi","ref":"e1","mode":"replace"}"#)
        #expect(type.command == .computer(.init(action: .type, windowID: 3, ref: "e1", text: "hi", mode: .replace)))
        let key = try decode("computer_key", #"{"window_id":3,"keys":"cmd+shift+4"}"#)
        #expect(key.command == .computer(.init(action: .key, windowID: 3, keys: "cmd+shift+4")))
        let scroll = try decode("computer_scroll", #"{"window_id":3,"ref":"e2","dy":-100}"#)
        #expect(scroll.command == .computer(.init(action: .scroll, windowID: 3, ref: "e2", dy: -100)))
        let drag = try decode("computer_drag", #"{"window_id":3,"ref":"e2","to_x":5,"to_y":6,"delivery":"direct"}"#)
        #expect(drag.command == .computer(.init(action: .drag, windowID: 3, ref: "e2", toX: 5, toY: 6, delivery: .direct)))
        let directScroll = try decode("computer_scroll", #"{"window_id":3,"x":1,"y":2,"dx":4,"delivery":"direct"}"#)
        #expect(directScroll.command == .computer(.init(action: .scroll, windowID: 3, x: 1, y: 2, dx: 4, delivery: .direct)))
        let openApp = try decode("computer_open_app", #"{"bundle_id":"com.apple.Notes"}"#)
        #expect(openApp.command == .computer(.init(action: .openApp, bundleID: "com.apple.Notes")))
        let wait = try decode("computer_wait", #"{"window_id":3,"query":"Done"}"#)
        #expect(wait.command == .computer(.init(
            action: .wait, windowID: 3, query: "Done", limit: 100, condition: .appear, timeoutMS: 5000
        )))
    }

    @Test(arguments: [
        ("computer_screenshot", "{}"),
        ("computer_inspect", #"{"window_id":1,"limit":0}"#),
        ("computer_inspect", #"{"window_id":1,"limit":3001}"#),
        ("computer_inspect", #"{"window_id":1,"max_depth":33}"#),
        ("computer_inspect", #"{"window_id":1,"query":"   "}"#),
        ("computer_inspect", "{\"window_id\":1,\"query\":\"\(String(repeating: "x", count: 257))\"}"),
        ("computer_apps", #"{"window_id":1}"#),
        ("computer_hover", #"{"window_id":1}"#),
        ("computer_click", #"{"window_id":1}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","x":1,"y":2}"#),
        ("computer_click", #"{"window_id":1,"x":1}"#),
        ("computer_click", #"{"window_id":1,"ref":"e0"}"#),
        ("computer_click", #"{"window_id":1,"ref":"x1"}"#),
        ("computer_click", #"{"window_id":1,"ref":"e100000"}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","count":3}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","button":"middle"}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","delivery":"loud"}"#),
        ("computer_click", #"{"window_id":1,"x":-1,"y":2}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","limit":0}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","text":"x"}"#),
        ("computer_type", #"{"window_id":1,"text":""}"#),
        ("computer_type", "{\"window_id\":1,\"text\":\"\(String(repeating: "x", count: 10001))\"}"),
        ("computer_type", #"{"window_id":1,"text":"x","mode":"replace"}"#),
        ("computer_key", #"{"window_id":1,"keys":"   "}"#),
        ("computer_key", "{\"window_id\":1,\"keys\":\"\(String(repeating: "k", count: 65))\"}"),
        ("computer_key", #"{"keys":"a"}"#),
        ("computer_scroll", #"{"window_id":1,"ref":"e1"}"#),
        ("computer_scroll", #"{"window_id":1,"ref":"e1","dy":101}"#),
        ("computer_drag", #"{"window_id":1,"ref":"e1"}"#),
        ("computer_drag", #"{"window_id":1,"ref":"e1","to_ref":"e2","to_x":1,"to_y":1}"#),
        ("computer_open_app", #"{"name":"Notes","bundle_id":"com.apple.Notes"}"#),
        ("computer_open_app", "{}"),
        ("computer_open_app", #"{"name":"Notes","include_screenshot":true}"#),
        ("computer_wait", #"{"window_id":1}"#),
        ("computer_wait", #"{"window_id":1,"query":"a","timeout_ms":50}"#),
        ("computer_wait", #"{"window_id":1,"query":"a","timeout_ms":20001}"#),
        ("computer_wait", #"{"window_id":1,"query":"a","include_screenshot":true}"#),
        ("computer_inspect", #"{"window_id":1,"ref":"e1"}"#),
        ("computer_screenshot", #"{"window_id":1,"call_id":"  "}"#),
        ("computer_screenshot", "{\"window_id\":1,\"call_id\":\"\(String(repeating: "x", count: 129))\"}"),
        ("computer_cancel", "{}"),
        ("computer_cancel", #"{"call_id":"c","window_id":1}"#),
        ("computer_cancel", #"{"call_id":"c","limit":300}"#),
    ])
    func rejectsInvalidRequests(command: String, params: String) {
        #expect(throws: AlasCLIRequestError.self) { try decode(command, params) }
    }
}
