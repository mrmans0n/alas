import CoreGraphics
import Testing
@testable import Alas

@MainActor
struct MermaidViewerStateTests {
    @Test("zoom clamps and resets")
    func zoomState() {
        var state = MermaidZoomState()
        state.zoom(by: 100)
        state.translate(by: CGSize(width: 24, height: -12))

        #expect(state.scale == MermaidZoomState.maximumScale)
        #expect(state.translation == CGSize(width: 24, height: -12))

        state.resetToFit()

        #expect(state.scale == 1)
        #expect(state.translation == .zero)
    }

    @Test("zoom clamps at minimum")
    func minimumZoom() {
        var state = MermaidZoomState()

        state.zoom(by: 0.001)

        #expect(state.scale == MermaidZoomState.minimumScale)
    }

    @Test("latest render key wins when an obsolete render completes last")
    func latestRenderKeyWins() {
        let obsoleteKey = TestMermaid.key(source: "graph TD; obsolete")
        let latestKey = TestMermaid.key(source: "graph TD; latest")
        var state = MermaidRenderRequestState()
        state.begin(obsoleteKey)
        state.begin(latestKey)
        state.apply(.failed(.unsupported("latest result")), for: latestKey)
        state.apply(.failed(.unsupported("obsolete result")), for: obsoleteKey)

        #expect(state.currentKey == latestKey)
        if case .failed(let failure) = state.outcome {
            #expect(failure == .unsupported("latest result"))
        } else {
            Issue.record("Expected the latest render failure to remain visible")
        }
    }
}
