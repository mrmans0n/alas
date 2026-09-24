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

    @Test func codePaneRefreshesInstalledStatusWithoutChangingTabs() async throws {
        struct MemoryStore: PersistenceStoreProtocol {
            func write<T: Encodable>(_: T, to _: URL) throws {}
            func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = directory.appendingPathComponent("test-language-server").path
        let language = "test-language-\(UUID().uuidString)"
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false)
        state.config.code.languageServers = [
            LanguageServerConfig(
                language: language, extensions: ["testlang"], command: command,
                args: [], env: [:], rootMarkers: [], enabled: true
            )
        ]

        var renderedStatuses: [LanguageServerAvailability.Status] = []
        var pane = CodePane(state: state)
        pane.onStatusRenderedForTesting = { renderedLanguage, status in
            if renderedLanguage == language { renderedStatuses.append(status) }
        }
        let controller = NSHostingController(rootView: pane.environment(\.theme, try ThemeStore().current))
        controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 1400)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.view.frame.size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        controller.view.layoutSubtreeIfNeeded()
        #expect(renderedStatuses.contains(.notInstalled))

        await state.lspInstaller._spawnForTesting(
            executable: "/bin/cp", arguments: ["/bin/echo", command], language: language
        )
        let deadline = Date().addingTimeInterval(2)
        while !renderedStatuses.contains(.available), Date() < deadline {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.lspInstaller.state == .finished(language: language, exitCode: 0))
        #expect(renderedStatuses.contains(.available))
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
