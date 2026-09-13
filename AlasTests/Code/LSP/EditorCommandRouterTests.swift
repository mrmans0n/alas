import Foundation
import Testing
@testable import Alas

@MainActor
struct EditorCommandRouterTests {
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
}
