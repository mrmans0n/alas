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

    @Test("a live reasoning preview does not make the collapsed header taller")
    func livePreviewPreservesHeaderHeight() throws {
        let theme = try ThemeStore().current
        let narration = ACPToolCallGroupLiveNarration(
            kind: .thinking,
            buffer: StreamingText(String(repeating: "Inspecting transcript state. ", count: 20))
        )

        #expect(
            headerHeight(expanded: false, theme: theme, liveNarration: narration)
                == headerHeight(expanded: false, theme: theme)
        )
    }

    @Test("live reasoning preview uses and bounds the latest non-empty line")
    func livePreviewUsesBoundedLatestLine() {
        let longTail = Array(repeating: "latest", count: 40).joined(separator: " ")
        let preview = ACPToolCallGroupLiveNarration.previewText(
            in: "old reasoning\n   \n  \(longTail)  \n"
        )

        #expect(!preview.contains("old reasoning"))
        #expect(preview.count == ACPToolCallGroupLiveNarration.previewCharacterLimit)
        #expect(longTail.hasSuffix(preview))
    }

    @Test("a member row renders the card handed to it")
    func memberRowRendersItsContent() throws {
        let theme = try ThemeStore().current
        #expect(memberHeight(lines: 20, theme: theme) > memberHeight(lines: 1, theme: theme))
    }

    /// The absorb pulse is allowed to recolor the lane and nothing else.
    /// Anything that changes the row's intrinsic height — a glow's padding, a
    /// scale, a thicker bar — reaches the scroller through
    /// `ACPTranscriptRowHostingView.invalidateIntrinsicContentSize`, and the
    /// reconciler answers a changed height with a full relayout pass. Every
    /// frame of the pulse would then re-tile the transcript under the reader.
    @Test("the lane's height does not change while the absorb pulse is lit")
    func laneHeightIsIndependentOfHighlight() throws {
        let theme = try ThemeStore().current
        #expect(laneHeight(highlight: 1, theme: theme) == laneHeight(highlight: 0, theme: theme))
    }

    private func laneHeight(highlight: Double, theme: Theme) -> CGFloat {
        measure(
            ACPToolCallGroupLane(highlight: highlight) {
                Text("Ran 3 tools")
            },
            theme: theme
        )
    }

    private func headerHeight(
        expanded: Bool,
        theme: Theme,
        liveNarration: ACPToolCallGroupLiveNarration? = nil
    ) -> CGFloat {
        measure(
            ACPToolCallGroupHeaderRow(
                summary: ACPToolCallGroupSummary(
                    toolCalls: [.init(toolCallId: "a", title: "a", status: "completed")]
                ),
                expanded: expanded,
                liveNarration: liveNarration
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
