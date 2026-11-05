import CoreGraphics
import Testing
@testable import Alas

struct WebPreviewViewportTests {
    @Test(arguments: [
        (390, 844, CGSize(width: 900, height: 900)),
        (390, 844, nil as CGSize?),
        (390, 844, CGSize.zero),
    ])
    func viewportThatFitsOrHasNoPaneShowsAtActualSize(width: Int, height: Int, pane: CGSize?) {
        let viewport = WebPreviewViewport(width: width, height: height)
        #expect(WebPreviewSurfaceLayout.fit(viewport, in: pane) == WebPreviewSurfaceLayout(size: viewport.size, zoom: 1))
    }

    /// WebKit lays out at `floor(frame / zoom)`. Every size must land exactly
    /// and stay in the pane, except that height may give way at extreme zoom.
    @Test func zoomedLayoutLandsOnTheExactWidthAndStaysInThePane() {
        for preset in [(390, 844), (820, 1180), (1280, 800), (1920, 1080), (1441, 901), (4096, 4096), (200, 4096)] {
            for pane in stride(from: 150, through: 1900, by: 37) {
                for aspect in [0.5, 0.75, 1.2] {
                    let viewport = WebPreviewViewport(width: preset.0, height: preset.1)
                    let paneSize = CGSize(width: Double(pane), height: (Double(pane) * aspect).rounded())
                    let layout = WebPreviewSurfaceLayout.fit(viewport, in: paneSize)
                    guard layout.zoom < 1 else { continue }
                    // WebKit holds the zoom as a Float.
                    let laidOut = Double(layout.size.width) / Double(Float(layout.zoom))
                    #expect(Int(laidOut.rounded(.down)) == preset.0, "\(preset) in \(paneSize): \(layout)")
                    #expect(layout.size.width <= paneSize.width)
                    #expect(layout.size.height <= paneSize.height + 1)
                    let laidOutHeight = Double(layout.size.height) / layout.zoom
                    #expect(abs(laidOutHeight.rounded(.down) - Double(preset.1)) <= (1 / layout.zoom).rounded(.up))
                }
            }
        }
    }

    @Test(arguments: [
        ("390", "844", WebPreviewViewport(width: 390, height: 844) as WebPreviewViewport?),
        (" 390 ", "844", WebPreviewViewport(width: 390, height: 844)),
        ("199", "844", nil),
        ("390", "4097", nil),
        ("", "844", nil),
        ("39.5", "844", nil),
    ])
    func typedSizesParseWithinAgentBounds(width: String, height: String, expected: WebPreviewViewport?) {
        #expect(WebPreviewViewport(width: width, height: height) == expected)
    }

    @Test(arguments: [
        (WebPreviewViewport(width: 390, height: 844), "Phone 390×844"),
        (WebPreviewViewport(width: 844, height: 390), "Phone 844×390"),
        (WebPreviewViewport(width: 500, height: 500), "500×500"),
    ])
    func labelNamesPresetsInEitherOrientation(viewport: WebPreviewViewport, label: String) {
        #expect(viewport.label == label)
    }

    @Test func captureReductionOnlyAppliesOverTheLimitAndLandsUnderIt() {
        #expect(WebPreviewSurfaceLayout.captureReduction(pixelWidth: 2000, pixelHeight: 4000, maximumPixels: 8_000_000) == 1)
        let reduction = WebPreviewSurfaceLayout.captureReduction(pixelWidth: 3840, pixelHeight: 2160, maximumPixels: 8_000_000)
        #expect(reduction < 1)
        #expect(ceil(3840 * reduction) * ceil(2160 * reduction) <= 8_000_000)
    }
}
