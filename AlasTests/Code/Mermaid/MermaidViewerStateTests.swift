import CoreGraphics
import Testing
@testable import Alas

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
}
