import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
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

    @Test(arguments: [
        (#"{"reduce-motion":"on","show-borders":"off","reduce-transparency":"on","voiceover":"off","color-filter":"red-green","liquid-glass":"tinted"}"#,
         SimulatorAccessibility(
             voiceOver: .value(false), reduceMotion: .value(true), buttonShapes: .value(false),
             reduceTransparency: .value(true), colorFilter: .value(.redGreen), liquidGlass: .value(.tinted)
         )),
        // An older runtime without Liquid Glass, and a value this version doesn't know.
        (#"{"reduce-motion":"off","show-borders":"on","reduce-transparency":"off","voiceover":"on","color-filter":"sepia"}"#,
         SimulatorAccessibility(
             voiceOver: .value(true), reduceMotion: .value(false), buttonShapes: .value(true),
             reduceTransparency: .value(false), colorFilter: .unknown, liquidGlass: .unknown
         )),
    ] as [(String, SimulatorAccessibility)])
    func accessibilityStatusParsesEachKey(status: String, expected: SimulatorAccessibility) throws {
        #expect(try SimulatorAccessibility.parse(Data((status + "\n").utf8)) == expected)
    }

    @Test(arguments: [
        ("26.5", true), ("27.0", true), ("18.5", false), (nil, true),
    ] as [(String?, Bool)])
    func liquidGlassIsOnlyOnIOS26AndLater(runtimeVersion: String?, supported: Bool) throws {
        let status = Data(#"{"liquid-glass":"clear"}"#.utf8)
        #expect(SimulatorAccessibility.supportsLiquidGlass(runtimeVersion: runtimeVersion) == supported)
        #expect(try SimulatorAccessibility.parse(status, runtimeVersion: runtimeVersion).liquidGlass
            == (supported ? .value(.clear) : .unsupported))
    }

    @Test func accessibilityStatusThatIsNotAnObjectIsUnreadable() {
        #expect(throws: SimulatorAccessibilityError.unreadable) {
            try SimulatorAccessibility.parse(Data("sim-ax-settings: missing symbol".utf8))
        }
    }

    @Test func accessibilityReadBackJSONUsesTheToolsKeys() throws {
        let read = SimulatorAccessibility(
            voiceOver: .value(true), reduceMotion: .value(false), buttonShapes: .unknown,
            reduceTransparency: .value(false), colorFilter: .value(.grayscale), liquidGlass: .value(.clear)
        )
        let data = try JSONSerialization.data(withJSONObject: read.json, options: .sortedKeys)
        #expect(String(decoding: data, as: UTF8.self) == #"{"button_shapes":"unknown","color_filter":"grayscale","liquid_glass":"clear","reduce_motion":false,"reduce_transparency":false,"voiceover":true}"#)
    }

    @Test func anAccessibilityChangeSetsOnlyItsKeysInAFixedOrder() {
        let change = SimulatorAccessibilityChange(voiceOver: false, colorFilter: .blueYellow, liquidGlass: .tinted)
        #expect(change.helperArguments == [
            ["set", "voiceover", "off"], ["set", "color-filter", "blue-yellow"], ["set", "liquid-glass", "tinted"],
        ])
        #expect(SimulatorAccessibilityChange().isEmpty)
    }

    @Test func accessibilityWithoutTheHelperFailsSayingSo() async {
        let settings = LiveSimulatorSettings(accessibilityHelper: nil)
        await #expect(throws: SimulatorAccessibilityError.helperMissing) { try await settings.accessibility(udid: "U") }
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

struct SimulatorPasteAccessTests {
    @Test func readsTheAppsPasteboardRowFromTCC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.allowed', 2);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.denied', 0);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.asks', 1);
            INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.camera', 2);
            """, nil, nil, nil)
        sqlite3_close(db)

        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.allowed") == .allowed)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.denied") == .denied)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.asks") == .notSet)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.camera") == .notSet)
        #expect(SimulatorPasteAccess.read(database: url.appendingPathExtension("missing"), bundleID: "x") == .notSet)
    }
}
