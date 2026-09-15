import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct EditorCommandRouterTests {
    @Test(arguments: [false, true]) func dismissedMenuDoesNotRetargetKeyboardCommand(nativeAction: Bool) throws {
        let view = makeTextView("first second")
        var invoked: NSRange?
        let router = EditorCommandRouter(capabilities: try LSPCapabilities(json: Data(#"{"referencesProvider":true}"#.utf8)), isServerReady: true,
                                         handlers: [.references: { invoked = $0 }])
        view.editorCommandRouter = router
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .init(x: 4, y: 4), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = view.menu(for: event)
        if nativeAction { view.selectAll(nil) }
        view.setSourceSelectedRange(NSRange(location: 8, length: 0))
        view.findReferences(nil)
        #expect(invoked == NSRange(location: 8, length: 0))
    }

    @Test func installedContextShortcutsAreBareFunctionKeysAndActionOwnsClickedRange() throws {
        let view = makeTextView("first second")
        var invoked: NSRange?
        view.editorCommandRouter = EditorCommandRouter(capabilities: .init(supportedCommands: [.definition, .rename]), isServerReady: true,
            handlers: [.definition: { invoked = $0 }, .rename: { invoked = $0 }])
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .init(x: 4, y: 4), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.menu(for: event))
        let definition = try #require(menu.items.first { $0.title == "Go to Definition" })
        let rename = try #require(menu.items.first { $0.title == "Rename Symbol" })
        #expect(definition.keyEquivalentModifierMask.isEmpty)
        #expect(rename.keyEquivalentModifierMask.isEmpty)
        #expect(definition.keyEquivalent.unicodeScalars.first?.value == UInt32(NSF12FunctionKey))
        #expect(rename.keyEquivalent.unicodeScalars.first?.value == UInt32(NSF2FunctionKey))
        #expect(NSApp.sendAction(try #require(definition.action), to: definition.target, from: definition))
        let menuRange = try #require(invoked)
        invoked = nil
        view.setSourceSelectedRange(.init(location: 8, length: 0))
        #expect(NSApp.sendAction(try #require(definition.action), to: definition.target, from: definition))
        #expect(invoked == menuRange)
        #expect(invoked != NSRange(location: 8, length: 0))
        view.goToDefinition(nil)
        #expect(invoked == NSRange(location: 8, length: 0))
    }

    @Test func clickInsideSelectionPreservesRange() {
        let selection = NSRange(location: 4, length: 5)
        #expect(EditorCommandRouter.targetRange(clickOffset: 6,
            selection: selection) == selection)
        #expect(EditorCommandRouter.targetRange(clickOffset: 12,
            selection: selection) == NSRange(location: 12, length: 0))
    }

    @Test("menu availability uses the capability snapshot without invoking handlers")
    func menuAvailabilityDoesNotInvokeHandlers() throws {
        let capabilities = try LSPCapabilities(json: Data("""
        {"hoverProvider":true,"definitionProvider":true,"documentFormattingProvider":true}
        """.utf8))
        var invocations = 0
        let router = EditorCommandRouter(
            capabilities: capabilities,
            isServerReady: true,
            handlers: [
                .hover: { _ in invocations += 1 },
                .definition: { _ in invocations += 1 },
                .formatDocument: { _ in invocations += 1 }
            ]
        )

        #expect(router.availableCommands() == [.definition, .formatDocument, .hover])
        #expect(invocations == 0)
    }

    @Test("server readiness disables a supported command without discarding its snapshot")
    func readinessSeparatesFromSupport() throws {
        let capabilities = try LSPCapabilities(json: Data(#"{"hoverProvider":true}"#.utf8))
        let router = EditorCommandRouter(
            capabilities: capabilities,
            isServerReady: false,
            handlers: [.hover: { _ in }]
        )

        #expect(capabilities.supports(.hover))
        #expect(router.availableCommands().isEmpty)
    }

    @Test("local history commands do not wait for a language server")
    func localHistoryCommandsUseTheirOwnAvailability() {
        var canGoBack = false
        let router = EditorCommandRouter()
        router.register(.back, isAvailable: { canGoBack }) { _ in }

        #expect(!router.availableCommands().contains(.back))

        canGoBack = true
        #expect(router.availableCommands().contains(.back))
    }

    @Test("problem navigation is locally available only when diagnostics exist")
    func problemNavigationUsesItsAvailabilityCheck() {
        var hasDiagnostics = false
        let router = EditorCommandRouter()
        router.register(.nextProblem, isAvailable: { hasDiagnostics }) { _ in }
        router.register(.previousProblem, isAvailable: { hasDiagnostics }) { _ in }

        #expect(!router.availableCommands().contains(.nextProblem))
        #expect(!router.availableCommands().contains(.previousProblem))

        hasDiagnostics = true
        #expect(router.availableCommands().contains(.nextProblem))
        #expect(router.availableCommands().contains(.previousProblem))
    }

    @Test("app command availability exposes only registered active commands")
    func appCommandAvailabilityGatesFutureCommands() throws {
        let capabilities = try LSPCapabilities(json: Data(#"{"definitionProvider":true,"renameProvider":true}"#.utf8))
        let router = EditorCommandRouter(
            capabilities: capabilities,
            isServerReady: true,
            handlers: [.definition: { _ in }]
        )
        let availability = EditorCommandAvailability()

        availability.activate(router)

        #expect(availability.isAvailable(.definition))
        #expect(!availability.isAvailable(.rename))

        availability.clear()

        #expect(!availability.activeEditor)
        #expect(!availability.isAvailable(.definition))
    }

    @Test("opening the editor menu preserves native commands without LSP traffic")
    func menuOpeningDoesNotSendLSPRequests() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        defer { transport.finish() }
        let capabilities = try LSPCapabilities(json: Data(#"{"hoverProvider":true}"#.utf8))
        var handlerInvocations = 0
        let router = EditorCommandRouter(
            capabilities: capabilities,
            isServerReady: true,
            handlers: [.hover: { _ in
                handlerInvocations += 1
                Task {
                    _ = try? await client.hover(
                        uri: "file:///tmp/value.swift",
                        position: LSPPosition(line: 0, character: 0)
                    )
                }
            }]
        )
        let textView = makeTextView("value")
        let nativeMenu = NSMenu()
        nativeMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        nativeMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
        textView.menu = nativeMenu
        textView.editorCommandRouter = router
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 4, y: 4),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let menu = textView.menu(for: event)

        #expect(menu?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true)
        #expect(menu?.items.contains { $0.action == #selector(NSText.selectAll(_:)) } == true)
        #expect(menu?.items.contains { $0.title == "Show Hover" } == true)
        #expect(handlerInvocations == 0)
        await Task.yield()
        #expect(transport.sent.isEmpty)
    }

    private func makeTextView(_ text: String) -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        return textView
    }
}
