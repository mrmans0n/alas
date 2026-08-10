import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ACPToolCallCardTests {
    @Test("expanded text output belongs to the transcript scroll surface")
    func expandedTextOutputHasNoNestedScrollView() throws {
        let card = ACPToolCallCard(toolCall: ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "Run",
            status: "completed",
            content: String(repeating: "output line\n", count: 80)
        ), initiallyExpanded: true)
        .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: card)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
        drainSwiftUI(controller.view)

        #expect(descendants(of: controller.view).compactMap { $0 as? NSScrollView }.isEmpty)
    }

    private func drainSwiftUI(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
