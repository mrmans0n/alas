import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptRowHostingView measurement")
struct ACPTranscriptRowHostingViewTests {
    @Test("measures positive height for a text row at a fixed width")
    func measuresText() {
        let view = ACPTranscriptRowHostingView(
            rootView: AnyView(Text("hello world").font(.system(size: 13)))
        )
        let height = view.measuredHeight(forWidth: 400)
        #expect(height > 0)
        #expect(height < 100)
    }

    @Test("longer content measures taller at the same width")
    func longerContentIsTaller() {
        let short = ACPTranscriptRowHostingView(
            rootView: AnyView(Text("one line").frame(maxWidth: .infinity, alignment: .leading))
        )
        let long = ACPTranscriptRowHostingView(
            rootView: AnyView(
                Text(String(repeating: "a fairly long sentence that will wrap. ", count: 20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        #expect(long.measuredHeight(forWidth: 300) > short.measuredHeight(forWidth: 300))
    }

    @Test("narrower width measures taller for wrapping content")
    func narrowerWidthIsTaller() {
        let view = ACPTranscriptRowHostingView(
            rootView: AnyView(
                Text(String(repeating: "wrap me please ", count: 30))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        #expect(view.measuredHeight(forWidth: 200) > view.measuredHeight(forWidth: 600))
    }

    @Test("intrinsic size invalidation fires the callback")
    func invalidationCallback() {
        let view = ACPTranscriptRowHostingView(rootView: AnyView(Text("x")))
        var fired = 0
        view.onIntrinsicSizeInvalidated = { fired += 1 }
        view.invalidateIntrinsicContentSize()
        #expect(fired == 1)
    }

    @Test("lastMeasuredWidth reflects the last successful measurement")
    func lastMeasuredWidthTracksMeasurement() {
        let view = ACPTranscriptRowHostingView(rootView: AnyView(Text("hello world")))
        #expect(view.lastMeasuredWidth == nil)

        _ = view.measuredHeight(forWidth: 320)
        #expect(view.lastMeasuredWidth == 320)

        _ = view.measuredHeight(forWidth: 150)
        #expect(view.lastMeasuredWidth == 150)
    }

    @Test("non-positive width is rejected without pinning the view to a degenerate frame")
    func nonPositiveWidthIsRejected() {
        let freshView = ACPTranscriptRowHostingView(rootView: AnyView(Text("hello world")))
        #expect(freshView.measuredHeight(forWidth: 0) == 0)
        #expect(freshView.lastMeasuredWidth == nil)
        #expect(freshView.measuredHeight(forWidth: -50) == 0)
        #expect(freshView.lastMeasuredWidth == nil)

        let measuredView = ACPTranscriptRowHostingView(rootView: AnyView(Text("hello world")))
        _ = measuredView.measuredHeight(forWidth: 320)
        #expect(measuredView.lastMeasuredWidth == 320)

        #expect(measuredView.measuredHeight(forWidth: 0) == 0)
        #expect(measuredView.lastMeasuredWidth == 320)

        #expect(measuredView.measuredHeight(forWidth: -10) == 0)
        #expect(measuredView.lastMeasuredWidth == 320)
    }

    @Test("updateRootView replaces the pristine base, so a later measurement reflects the new content")
    func updateRootViewReplacesPristineBase() {
        let view = ACPTranscriptRowHostingView(
            rootView: AnyView(Text("short").frame(maxWidth: .infinity, alignment: .leading))
        )
        let shortHeight = view.measuredHeight(forWidth: 300)

        view.updateRootView(
            AnyView(
                Text(String(repeating: "a fairly long sentence that will wrap. ", count: 20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        let longHeight = view.measuredHeight(forWidth: 300)

        // If updateRootView failed to refresh the internal pristine copy,
        // this second measurement would re-pin the ORIGINAL short content
        // and longHeight would equal shortHeight.
        #expect(longHeight > shortHeight)
    }

    /// A hovered row must settle. Reacting to hover by republishing state
    /// (as the message gutter does) used to resubscribe the hover stream on
    /// every render and replay its value, so a row under the pointer
    /// re-rendered itself until the app beachballed.
    @Test("a hovered row reports the hover once and settles")
    func hoveredRowSettles() async throws {
        let probe = HoverProbe()
        let view = ACPTranscriptRowHostingView(rootView: AnyView(HoverProbeView(probe: probe)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        _ = view.measuredHeight(forWidth: 300)
        window.layoutIfNeeded()

        view.hover.isHovered = true
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline, probe.enters < 50 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(probe.enters == 1)
    }
}

@MainActor
private final class HoverProbe: ObservableObject {
    @Published var revision = 0
    var enters = 0
}

private struct HoverProbeView: View {
    @ObservedObject var probe: HoverProbe

    var body: some View {
        Text("row \(probe.revision)")
            .acpRowHover { inside in
                guard inside else { return }
                probe.enters += 1
                probe.revision += 1
            }
    }
}
