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
            action: .click, windowID: 3, query: "ok", limit: 3000, maxDepth: 32, ref: "e12", button: .right, count: 2,
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
        let across = try decode("computer_drag", #"{"window_id":3,"ref":"e2","to_window_id":9,"to_ref":"e4","modifiers":["option","command"]}"#)
        #expect(across.command == .computer(.init(
            action: .drag, windowID: 3, ref: "e2", toWindowID: 9, toRef: "e4", modifiers: [.option, .command]
        )))
        let directScroll = try decode("computer_scroll", #"{"window_id":3,"x":1,"y":2,"dx":4,"delivery":"direct"}"#)
        #expect(directScroll.command == .computer(.init(action: .scroll, windowID: 3, x: 1, y: 2, dx: 4, delivery: .direct)))
        let openApp = try decode("computer_open_app", #"{"bundle_id":"com.apple.Notes"}"#)
        #expect(openApp.command == .computer(.init(action: .openApp, bundleID: "com.apple.Notes")))
        let wait = try decode("computer_wait", #"{"window_id":3,"query":"Done"}"#)
        #expect(wait.command == .computer(.init(
            action: .wait, windowID: 3, query: "Done", limit: 100, maxDepth: 32, condition: .appear, timeoutMS: 5000
        )))
    }

    /// An inspect's or input action's read searches every level a read may walk when it has a
    /// query, and 12 without one; an explicit max_depth always wins.
    @Test(arguments: [
        ("computer_click", #"{"window_id":1,"ref":"e1"}"#, 12),
        ("computer_click", #"{"window_id":1,"ref":"e1","query":"Save"}"#, 32),
        ("computer_type", #"{"window_id":1,"text":"x","query":"Save","max_depth":8}"#, 8),
        ("computer_key", #"{"window_id":1,"keys":"tab","max_depth":20}"#, 20),
        ("computer_inspect", #"{"window_id":1,"query":"Save"}"#, 32),
        ("computer_inspect", #"{"window_id":1}"#, 12),
        ("computer_wait", #"{"window_id":1,"query":"Done"}"#, 32),
    ])
    func defaultsTheReadDepth(command: String, params: String, depth: Int) throws {
        guard case .computer(let computer) = try decode(command, params).command else {
            Issue.record("not a computer command")
            return
        }
        #expect(computer.maxDepth == depth)
    }

    @Test(arguments: [
        ("computer_screenshot", "{}"),
        ("computer_click", #"{"window_id":1,"ref":"e1","max_depth":33}"#),
        ("computer_scroll", #"{"window_id":1,"ref":"e1","dy":1,"max_depth":0}"#),
        ("computer_wait", #"{"window_id":1,"query":"a","max_depth":12}"#),
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
        ("computer_drag", #"{"window_id":1,"ref":"e1","to_window_id":-1,"to_ref":"e2"}"#),
        ("computer_drag", #"{"window_id":1,"ref":"e1","to_ref":"e2","modifiers":["option","option"]}"#),
        ("computer_drag", #"{"window_id":1,"ref":"e1","to_ref":"e2","modifiers":["function"]}"#),
        ("computer_drag", #"{"window_id":1,"ref":"e1","to_ref":"e2","modifiers":["cmd"]}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","modifiers":["shift"]}"#),
        ("computer_click", #"{"window_id":1,"ref":"e1","to_window_id":2}"#),
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

    @Test func decodesVMCommandsWithTheirTimeoutBounds() throws {
        #expect(try decode("vm_run", #"{"command":"open x.app"}"#).command == .vmRun(command: "open x.app", timeoutSeconds: 120))
        #expect(try decode("vm_run", #"{"command":"make","timeout_seconds":1}"#).command == .vmRun(command: "make", timeoutSeconds: 1))
        #expect(try decode("vm_run", #"{"command":"make","timeout_seconds":600}"#).command == .vmRun(command: "make", timeoutSeconds: 600))
        #expect(try decode("vm_status", "{}").command == .vmStatus())
        #expect(try decode("vm_status", nil).command == .vmStatus())
        for params in [nil, "{}", #"{"command":"  "}"#, #"{"command":"ls","timeout_seconds":0}"#, #"{"command":"ls","timeout_seconds":601}"#] {
            #expect(throws: AlasCLIRequestError.self) { try decode("vm_run", params) }
        }
    }

    /// `vm` names the guest by its wire name, never by `VMGuestOS`'s persisted raw value.
    @Test func decodesTheTargetVM() throws {
        #expect(try decode("vm_run", #"{"command":"uname -a","vm":"linux"}"#).command
            == .vmRun(command: "uname -a", timeoutSeconds: 120, vm: .linux))
        #expect(try decode("vm_status", #"{"vm":"macos"}"#).command == .vmStatus(vm: .macOS))
        #expect(try decode("computer_screenshot", #"{"window_id":7,"vm":"linux"}"#).command
            == .computer(.init(action: .screenshot, windowID: 7, vm: .linux)))
        #expect(try decode("computer_cancel", #"{"call_id":"c","vm":"macos"}"#).command
            == .computer(.init(action: .cancel, callID: "c", vm: .macOS)))
        for (command, params) in [
            ("vm_run", #"{"command":"ls","vm":"macOS"}"#), ("vm_status", #"{"vm":"windows"}"#),
            ("vm_status", #"{"vm":1}"#), ("computer_apps", #"{"vm":"ubuntu"}"#),
        ] {
            #expect(throws: AlasCLIRequestError.self) { try decode(command, params) }
        }
    }

    /// The host routes on `vm`; a guest helper predating it would refuse the key.
    @Test func requestJSONLeavesTheTargetVMToTheHost() throws {
        let command = ComputerUseCommand(action: .screenshot, windowID: 7, vm: .macOS)
        var forwarded = command
        forwarded.vm = nil
        #expect(try ComputerUseCommand.decode(action: .screenshot, data: command.requestJSON()) == forwarded)
    }

    @Test(arguments: [
        ComputerUseCommand(action: .screenshot, windowID: 7, callID: "42-1"),
        ComputerUseCommand(action: .inspect, windowID: 42, query: "Save", limit: 50, maxDepth: 20),
        ComputerUseCommand(action: .click, windowID: 3, query: "ok", ref: "e12", button: .right, count: 2, delivery: .direct, includeScreenshot: true),
        ComputerUseCommand(action: .type, windowID: 3, ref: "e1", text: "héllo \"x\"", mode: .replace),
        ComputerUseCommand(action: .key, windowID: 3, keys: "cmd+shift+4"),
        ComputerUseCommand(action: .scroll, windowID: 3, x: 10.5, y: 20, dx: -5, dy: 40),
        ComputerUseCommand(action: .drag, windowID: 3, ref: "e1", toWindowID: 4, toX: 5, toY: 6, modifiers: [.option, .shift]),
        ComputerUseCommand(action: .openApp, bundleID: "com.apple.Notes"),
        ComputerUseCommand(action: .wait, windowID: 3, query: "Done", maxDepth: 32, condition: .disappear, timeoutMS: 9000),
        ComputerUseCommand(action: .apps),
        ComputerUseCommand(action: .cancel, callID: "42-1"),
    ])
    func requestJSONRoundTrips(command: ComputerUseCommand) throws {
        let data = try command.requestJSON()
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["command"] as? String == "computer_\(command.action.rawValue)")
        #expect(try ComputerUseCommand.decode(action: command.action, data: data) == command)
    }

    @Test(arguments: [
        AlasCLIResponse.ok, .text(["{\"a\":1}", "line"]), .error("nope"), .errorWithExitCode("bad", 3),
    ])
    func responseRoundTrips(response: AlasCLIResponse) throws {
        #expect(try AlasCLIResponse.decode(response.encode()) == response)
    }
}
