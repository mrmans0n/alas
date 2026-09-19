import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ACPToolCallGroupRowTests {
    /// The header is only ever the toggle: an expanded bundle's cards are
    /// tiled as their own sibling rows, not nested inside this view. If the
    /// header grew when expanded, the members would be inside it again and
    /// the scroller would lose their individual geometry.
    @Test("the header row's height does not depend on whether the bundle is expanded")
    func headerHeightIsIndependentOfExpansion() throws {
        let theme = try ThemeStore().current
        #expect(headerHeight(expanded: true, theme: theme) == headerHeight(expanded: false, theme: theme))
    }

    @Test("a member row renders the card handed to it")
    func memberRowRendersItsContent() throws {
        let theme = try ThemeStore().current
        #expect(memberHeight(lines: 20, theme: theme) > memberHeight(lines: 1, theme: theme))
    }

    private func headerHeight(expanded: Bool, theme: Theme) -> CGFloat {
        measure(
            ACPToolCallGroupHeaderRow(
                summary: ACPToolCallGroupSummary(
                    toolCalls: [.init(toolCallId: "a", title: "a", status: "completed")]
                ),
                expanded: expanded
            ),
            theme: theme
        )
    }

    private func memberHeight(lines: Int, theme: Theme) -> CGFloat {
        measure(
            ACPToolCallGroupMemberRow {
                Text(String(repeating: "member content line\n", count: lines))
            },
            theme: theme
        )
    }

    private func measure(_ view: some View, theme: Theme) -> CGFloat {
        let root = view
            .environment(\.theme, theme)
            .frame(width: 400)
        let controller = NSHostingController(rootView: root)
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
