import Foundation
import Testing
@testable import AlasCore

struct DeviceCommandTests {
    private func decode(_ command: String, _ params: String?) throws -> AlasCLIRequest.Command {
        let tail = params.map { ",\"params\":\($0)" } ?? ""
        let json = "{\"v\":1,\"kind\":\"cli\",\"session_id\":\"s\",\"command\":\"\(command)\"\(tail)}"
        return try AlasCLIRequest.decode(from: Data(json.utf8)).command
    }

    @Test(arguments: [
        ("device_list", "{}", DeviceCommand.list),
        ("device_open", #"{"udid":"U"}"#, .open(udid: "U")),
        ("device_snapshot", #"{"udid":"U"}"#, .snapshot(udid: "U", query: nil, limit: 200)),
        ("device_snapshot", #"{"udid":"U","query":"Save","limit":5}"#, .snapshot(udid: "U", query: "Save", limit: 5)),
        ("device_screenshot", #"{"udid":"U"}"#, .screenshot(udid: "U")),
        ("device_tap", #"{"udid":"U","ref":"s2e3"}"#, .tap(udid: "U", target: .ref("s2e3"), includeScreenshot: false)),
        ("device_tap", #"{"udid":"U","x":10.5,"y":20,"include_screenshot":true}"#,
         .tap(udid: "U", target: .point(x: 10.5, y: 20), includeScreenshot: true)),
        ("device_swipe", #"{"udid":"U","direction":"up"}"#,
         .swipe(udid: "U", gesture: .direction(.up), durationMs: 300, includeScreenshot: false)),
        ("device_swipe", #"{"udid":"U","from_x":1,"from_y":2,"to_x":3,"to_y":4,"duration_ms":50}"#,
         .swipe(udid: "U", gesture: .points(fromX: 1, fromY: 2, toX: 3, toY: 4), durationMs: 50, includeScreenshot: false)),
        ("device_type", #"{"udid":"U","text":" "}"#, .type(udid: "U", text: " ", includeScreenshot: false)),
        ("device_button", #"{"udid":"U","name":"home"}"#, .button(udid: "U", name: .home, includeScreenshot: false)),
        ("device_install", #"{"udid":"U","app_path":"/b/Hello.app"}"#, .install(udid: "U", appPath: "/b/Hello.app")),
        ("device_launch", #"{"udid":"U","bundle_id":"com.example.hello"}"#, .launch(udid: "U", bundleID: "com.example.hello")),
    ] as [(String, String, DeviceCommand)])
    func decodesEachActionWithDefaults(command: String, params: String, expected: DeviceCommand) throws {
        #expect(try decode(command, params) == .device(expected))
    }

    @Test(arguments: [
        ("device_list", #"{"udid":"U"}"#),
        ("device_screenshot", #"{"udid":"U","window_id":1}"#),
        ("device_tap", #"{"udid":"U","ref":"s1e1","x":1,"y":1}"#),
        ("device_tap", #"{"udid":"U","x":1}"#),
        ("device_tap", #"{"udid":"U","x":-1,"y":1}"#),
        ("device_swipe", #"{"udid":"U","direction":"up","from_x":1}"#),
        ("device_swipe", #"{"udid":"U","from_x":1,"from_y":2,"to_x":3}"#),
        ("device_swipe", #"{"udid":"U","direction":"up","duration_ms":10}"#),
        ("device_snapshot", #"{"udid":"U","limit":0}"#),
        ("device_type", #"{"udid":"U","text":""}"#),
        ("device_button", #"{"udid":"U","name":"volume"}"#),
        ("device_open", #"{}"#),
        ("device_install", #"{"udid":"U"}"#),
        ("device_install", #"{"udid":"U","app_path":"relative/Hello.app"}"#),
        ("device_launch", #"{"udid":"U","bundle_id":""}"#),
        ("device_launch", #"{"udid":"U","bundle_id":"x","include_screenshot":true}"#),
    ])
    func refusesWhatAnActionDoesNotTake(command: String, params: String) {
        #expect(throws: AlasCLIRequestError.malformed) { try decode(command, params) }
    }
}
