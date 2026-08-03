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
}
