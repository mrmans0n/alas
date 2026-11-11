import Foundation
import Testing
@testable import AlasCore

struct SimulatorSettingsTests {
    @Test(arguments: [
        ("dark", "accessibility-large", "enabled",
         SimulatorDisplaySettings(appearance: .value(.dark), textSize: .value(.accessibilityLarge), increaseContrast: .value(true))),
        ("unsupported", "unsupported", "unsupported",
         SimulatorDisplaySettings(appearance: .unsupported, textSize: .unsupported, increaseContrast: .unsupported)),
        ("unknown", "nonsense", "", SimulatorDisplaySettings(appearance: .unknown, textSize: .unknown, increaseContrast: .unknown)),
    ] as [(String, String, String, SimulatorDisplaySettings)])
    func readBackParsesValuesUnsupportedAndUnknown(appearance: String, size: String, contrast: String, expected: SimulatorDisplaySettings) {
        #expect(SimulatorDisplaySettings.parse(appearance: appearance + "\n", contentSize: size, increaseContrast: contrast) == expected)
    }

    @Test func readBackJSONReportsUnsupportedFields() throws {
        let settings = SimulatorDisplaySettings(appearance: .value(.light), textSize: .unsupported, increaseContrast: .value(false))
        let data = try JSONSerialization.data(withJSONObject: settings.json, options: .sortedKeys)
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"appearance":"light","increase_contrast":false,"text_size":"unsupported"}"#)
    }

    @Test func appListKeepsOnlyTheUsersAppsByName() throws {
        let plist: [String: Any] = [
            "com.apple.Preferences": ["ApplicationType": "System", "CFBundleDisplayName": "Settings"],
            "com.example.zeta": ["ApplicationType": "User", "CFBundleName": "Zeta"],
            "com.example.hello": ["ApplicationType": "User", "CFBundleDisplayName": "Hello"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(SimulatorAppList.parse(data) == [
            SimulatorApp(bundleID: "com.example.hello", name: "Hello"),
            SimulatorApp(bundleID: "com.example.zeta", name: "Zeta"),
        ])
    }

    @Test(arguments: [
        (#"{"aps":{"alert":"hi"}}"#, nil as String?),
        (#"[1]"#, "The payload must be a JSON object."),
        (#"{"alert":"hi"}"#, "The payload needs an \"aps\" object."),
        (#"{"aps":"hi"}"#, "The payload needs an \"aps\" object."),
        ("{\"aps\":{},\"x\":\"" + String(repeating: "a", count: 4100) + "\"}", "The payload is over 4096 bytes."),
    ] as [(String, String?)])
    func pushPayloadsAreCheckedBeforeSending(payload: String, problem: String?) {
        #expect(SimulatorPushPayload.problem(Data(payload.utf8)) == problem)
    }
}
