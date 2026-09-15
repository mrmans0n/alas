import Foundation
import Testing
@testable import Alas

struct AppConfigInlayHintsTests {
    private func decodeCode(_ code: String) throws -> AppConfig {
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults)) as? [String: Any])
        root["code"] = try JSONSerialization.jsonObject(with: Data(code.utf8))
        return try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: root))
    }

    @Test func oldConfigurationEnablesAllHintKinds() throws {
        let config = try decodeCode(#"{"fontSize":17}"#)
        #expect(config.code.inlayHintsByLanguage.isEmpty)
        #expect(config.code.inlayHints(for: "swift") == InlayHintSettings(enabled: true, parameters: true, types: true))
        #expect(config.code.fontSize == 17)
    }

    @Test func partialSettingsAndLanguageTogglePreserveOtherValues() throws {
        var config = try decodeCode(#"{"fontSize":17,"inlayHints":{"parameters":false},"inlayHintsByLanguage":{"ruby":{"types":false}}}"#)
        #expect(config.code.inlayHints(for: "swift") == InlayHintSettings(enabled: true, parameters: false, types: true))
        let ruby = config.code.inlayHintsByLanguage["ruby"]
        config.code.toggleInlayHints(for: "swift")
        #expect(config.code.inlayHints(for: "swift") == InlayHintSettings(enabled: false, parameters: false, types: true))
        #expect(config.code.inlayHintsByLanguage["ruby"] == ruby)
        let roundtrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(roundtrip.code == config.code)
        #expect(roundtrip.code.fontSize == 17)
    }

    @Test func unclassifiedHintsIgnoreKindFiltersButRespectEnabled() {
        let settings = InlayHintSettings(enabled: true, parameters: false, types: false)
        #expect(InlayHintsFeature.isVisible(kind: nil, settings: settings))
        #expect(InlayHintsFeature.isVisible(kind: 99, settings: settings))
        #expect(!InlayHintsFeature.isVisible(kind: 1, settings: settings))
        #expect(!InlayHintsFeature.isVisible(kind: 2, settings: settings))
        #expect(!InlayHintsFeature.isVisible(kind: nil, settings: .init(enabled: false)))
    }
}
