import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct CodeLanguageDetailViewTests {
    @Test(arguments: [false, true], [false, true])
    func hintEditsStayLocalUntilSave(save: Bool, inheritsAfterSave: Bool) {
        let entry = LanguageServerConfig(language: "swift", extensions: ["swift"], command: "sourcekit-lsp", args: [], env: [:], rootMarkers: [], enabled: true)
        var code = AppConfig.defaults.code
        code.languageServers = [entry]
        code.inlayHintsByLanguage["python"] = .init(enabled: false)
        if inheritsAfterSave { code.inlayHintsByLanguage["swift"] = .init(parameters: false) }
        let original = code
        var saves = 0
        var cancelled = false
        let model = CodeLanguageDetailModel(initial: entry,
                                            inlayHints: Binding(get: { code.inlayHintsByLanguage["swift"] }, set: { code.inlayHintsByLanguage["swift"] = $0 }),
                                            onSave: { saved, recipes in
                                                code.saveLanguageServerConfig(originalLanguage: "swift", saved, recipes: recipes)
                                                saves += 1
                                            }, onCancel: { cancelled = true })
        model.entry.command = " custom-lsp "
        model.inlayHints = inheritsAfterSave ? nil : .init(enabled: true, parameters: false, types: true)
        #expect(code == original)
        #expect(saves == 0)
        if save { model.save() } else { model.cancel() }
        #expect(cancelled == !save)
        #expect(saves == (save ? 1 : 0))
        if save {
            #expect(code.inlayHintsByLanguage["swift"] == (inheritsAfterSave ? nil : InlayHintSettings(enabled: true, parameters: false, types: true)))
            #expect(code.inlayHintsByLanguage["python"] == .init(enabled: false))
            #expect(code.languageServers.first?.command == "custom-lsp")
        } else {
            #expect(code == original)
        }
    }

    @Test func renamedLanguageMovesHintOverrideOnlyOnSave() {
        let entry = LanguageServerConfig(language: "swift", extensions: ["swift"], command: "sourcekit-lsp", args: [], env: [:], rootMarkers: [], enabled: true)
        var code = AppConfig.defaults.code
        code.languageServers = [entry]
        code.inlayHintsByLanguage["swift"] = .init(parameters: false)
        code.inlayHintsByLanguage["swift-new"] = .init(types: false)
        let original = code
        var saves = 0
        var cancelled = false
        let model = CodeLanguageDetailModel(initial: entry,
                                            inlayHints: Binding(get: { code.inlayHintsByLanguage["swift"] }, set: { code.inlayHintsByLanguage["swift"] = $0 }),
                                            onSave: { saved, recipes in
                                                code.saveLanguageServerConfig(originalLanguage: "swift", saved, recipes: recipes)
                                                saves += 1
                                            }, onCancel: { cancelled = true })
        let override = InlayHintSettings(enabled: true, parameters: true, types: false)
        model.entry.language = " swift-new "
        model.inlayHints = override

        model.cancel()

        #expect(cancelled)
        #expect(saves == 0)
        #expect(code == original)

        cancelled = false
        model.save()

        #expect(!cancelled)
        #expect(saves == 1)
        #expect(code.languageServers.map(\.language) == ["swift-new"])
        #expect(code.inlayHintsByLanguage["swift"] == nil)
        #expect(code.inlayHintsByLanguage["swift-new"] == override)
    }

    @Test func renamedLanguageUsingDefaultsRemovesOldAndDestinationOverrides() {
        let entry = LanguageServerConfig(language: "swift", extensions: ["swift"], command: "sourcekit-lsp", args: [], env: [:], rootMarkers: [], enabled: true)
        var code = AppConfig.defaults.code
        code.languageServers = [entry]
        code.inlayHintsByLanguage["swift"] = .init(parameters: false)
        code.inlayHintsByLanguage["swift-new"] = .init(types: false)
        let model = CodeLanguageDetailModel(initial: entry,
                                            inlayHints: Binding(get: { code.inlayHintsByLanguage["swift"] }, set: { code.inlayHintsByLanguage["swift"] = $0 }),
                                            onSave: { saved, recipes in
                                                code.saveLanguageServerConfig(originalLanguage: "swift", saved, recipes: recipes)
                                            }, onCancel: {})
        model.entry.language = "swift-new"
        model.inlayHints = nil

        model.save()

        #expect(code.inlayHintsByLanguage["swift"] == nil)
        #expect(code.inlayHintsByLanguage["swift-new"] == nil)
        #expect(code.inlayHints(for: "swift-new") == code.inlayHints)
    }

    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func newLanguageViewRendersWithoutCrashing() {
        let config = LanguageServerConfig(
            language: "",
            extensions: [],
            command: "",
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let view = CodeLanguageDetailView(
            initial: config,
            isNew: true,
            onSave: { _, _ in },
            onCancel: {}
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func existingLanguageViewRendersWithoutCrashing() {
        let config = LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: "sourcekit-lsp",
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let view = CodeLanguageDetailView(
            initial: config,
            isNew: false,
            onSave: { _, _ in },
            onCancel: {}
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }
}
