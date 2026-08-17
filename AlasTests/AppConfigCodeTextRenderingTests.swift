import Foundation
import Testing
@testable import Alas

@Suite("AppConfig code text rendering")
struct AppConfigCodeTextRenderingTests {
    private func decode(mutatingCode mutate: (inout [String: Any]) -> Void) throws -> AppConfig {
        let encoded = try JSONEncoder().encode(AppConfig.defaults)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var code = try #require(root["code"] as? [String: Any])
        mutate(&code)
        root["code"] = code
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    @Test func missingKeysUseProductDefaults() throws {
        let decoded = try decode { code in
            [
                "showInvisibleCharacters",
                "showSpaces",
                "showTabs",
                "showLineEndings",
                "showWarningCharacters",
                "warningCharacters",
            ].forEach { code.removeValue(forKey: $0) }
        }

        #expect(!decoded.code.showInvisibleCharacters)
        #expect(decoded.code.showSpaces && decoded.code.showTabs && decoded.code.showLineEndings)
        #expect(decoded.code.showWarningCharacters)
        #expect(decoded.code.warningCharacters == WarningCharacter.defaults)
    }

    @Test func explicitEmptyWarningListStaysEmpty() throws {
        let decoded = try decode { code in
            code["warningCharacters"] = []
        }

        #expect(decoded.code.warningCharacters.isEmpty)
    }

    @Test func decodedWarningsAreSanitized() throws {
        let decoded = try decode { code in
            code["warningCharacters"] = [
                ["scalarValue": 0x200B, "note": "First"],
                ["scalarValue": 0x110000, "note": "Invalid"],
                ["scalarValue": 0x200B, "note": "Second"],
            ]
        }

        #expect(decoded.code.warningCharacters == [WarningCharacter(scalarValue: 0x200B, note: "First")])
    }

    @Test func settingsRoundTrip() throws {
        var config = AppConfig.defaults
        config.code.showInvisibleCharacters = true
        config.code.showSpaces = false
        config.code.warningCharacters = [.init(scalarValue: 0x200B, note: "ZWSP")]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.code == config.code)
    }
}
