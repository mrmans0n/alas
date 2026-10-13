import AppKit
import Testing
@testable import Alas

@MainActor
@Suite struct ACPTranscriptCoreTextRowViewTests {
    private var theme: Theme { try! Theme.loadBundled(id: "cool-slate") }

    private func row(_ content: ACPTranscriptCoreTextRowView.Content) -> ACPTranscriptCoreTextRowView {
        let view = ACPTranscriptCoreTextRowView(frame: .zero)
        view.configure(content: content, contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default)
        return view
    }

    @Test func remeasuresAtANewWidth() {
        let view = row(.agent(markdown: String(repeating: "Words that wrap. ", count: 60), commentary: false))
        let wide = view.measuredHeight(forWidth: 1_000)
        let narrow = view.measuredHeight(forWidth: 400)
        #expect(narrow > wide)
        #expect(view.lastMeasuredWidth == 400)
        #expect(view.measuredHeight(forWidth: 0) == 0 && view.lastMeasuredWidth == 400)
    }

    @Test(arguments: [
        ACPTranscriptCoreTextRowView.Content.thought(label: "Planning"),
        .toolGroupHeader(label: "Ran 3 commands", iconSystemName: "terminal", expanded: false),
    ])
    func oneLineRowsAreOneLineTall(content: ACPTranscriptCoreTextRowView.Content) {
        let height = row(content).measuredHeight(forWidth: 1_000)
        #expect(height > 10 && height < 30)
    }

    @Test func theColumnIsCenteredAndCapped() {
        let view = row(.agent(markdown: "Hi", commentary: false))
        _ = view.measuredHeight(forWidth: 1_400)
        #expect(view.columnRect.width == 720)
        #expect(abs(view.columnRect.midX - 700) < 0.5)
    }

    @Test func reconfiguringWithNewContentInvalidatesTheHeight() {
        let view = row(.agent(markdown: "Short", commentary: false))
        let short = view.measuredHeight(forWidth: 800)
        var invalidated = false
        view.onIntrinsicSizeInvalidated = { invalidated = true }
        view.configure(content: .agent(markdown: String(repeating: "Longer text. ", count: 80), commentary: false),
                       contentMaxWidth: 720, inToolCallGroup: false, theme: theme, typography: .default)
        #expect(invalidated)
        #expect(view.measuredHeight(forWidth: 800) > short)
    }
}
