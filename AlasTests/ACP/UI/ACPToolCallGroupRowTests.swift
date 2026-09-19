import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ACPToolCallGroupRowTests {
    @Test("expanded renders the member content without needing a click")
    func expandedRendersTaller() throws {
        let theme = try ThemeStore().current
        #expect(height(expanded: true, theme: theme) > height(expanded: false, theme: theme))
    }

    private func height(expanded: Bool, theme: Theme) -> CGFloat {
        let row = ACPToolCallGroupRow(
            summary: ACPToolCallGroupSummary(toolCalls: [.init(toolCallId: "a", title: "a", status: "completed")]),
            expanded: expanded
        ) {
            Text(String(repeating: "member content line\n", count: 20))
        }
        .environment(\.theme, theme)
        .frame(width: 400)
        let controller = NSHostingController(rootView: row)
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 10)
        drainSwiftUI(controller.view)
        return controller.view.fittingSize.height
    }

    private func drainSwiftUI(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }
}
