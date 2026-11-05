import CoreGraphics
import Foundation

/// A page size in CSS pixels. This sizes the layout only: WebKit cannot
/// emulate a device's touch input or pixel density.
struct WebPreviewViewport: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Typed values, or nil unless both are whole sizes agents could also set.
    init?(width: String, height: String) {
        func parsed(_ text: String) -> Int? {
            Int(text.trimmingCharacters(in: .whitespaces)).flatMap { WebPreviewCommand.viewportDimensions.contains($0) ? $0 : nil }
        }
        guard let width = parsed(width), let height = parsed(height) else { return nil }
        self.init(width: width, height: height)
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var rotated: Self { Self(width: height, height: width) }

    struct Preset: Identifiable {
        let name: String
        let viewport: WebPreviewViewport
        var id: String { name }
    }

    static let presets = [
        Preset(name: "Phone", viewport: Self(width: 390, height: 844)),
        Preset(name: "Tablet", viewport: Self(width: 820, height: 1180)),
        Preset(name: "Laptop", viewport: Self(width: 1280, height: 800)),
        Preset(name: "Desktop", viewport: Self(width: 1920, height: 1080)),
    ]

    /// "Phone 390×844", in either orientation, or just the size.
    var label: String {
        let size = "\(width)×\(height)"
        let preset = Self.presets.first { $0.viewport == self || $0.viewport == rotated }
        return preset.map { "\($0.name) \(size)" } ?? size
    }
}

/// How a fixed viewport sits in the tab's pane: at real size if it fits, or
/// zoomed out to fit. Zooming the page rather than transforming the view keeps
/// it sharp and leaves AppKit's event handling alone. At a zoom other than 1
/// the page reports a matching `devicePixelRatio`, so `srcset` picks may differ.
struct WebPreviewSurfaceLayout: Equatable {
    var size: CGSize
    var zoom: Double

    /// WebKit lays out at `floor(frame / zoom)`, on a whole-pixel frame, so a
    /// plain fit lands a pixel or two short. That can flip a `min-width` rule
    /// at the very width being tested. This picks a whole-pixel frame and a
    /// zoom that land exactly on the viewport, trying slightly smaller frames
    /// until the height lands too. Width wins when both cannot.
    static func fit(_ viewport: WebPreviewViewport, in pane: CGSize?) -> Self {
        let actualSize = Self(size: viewport.size, zoom: 1)
        guard let pane, pane.width >= 1, pane.height >= 1 else { return actualSize }
        let width = Double(viewport.width)
        let height = Double(viewport.height)
        let fit = min(pane.width / width, pane.height / height)
        guard fit < 1 else { return actualSize }

        // Half a pixel in from the edge, so float rounding in WebKit's zoom
        // cannot tip the division under the whole number.
        func zoom(frameWidth: Double) -> Double { frameWidth / (width + 0.5) }
        let largest = max(1, floor(width * fit))
        for frameWidth in stride(from: largest, to: max(0, largest - 64), by: -1) {
            let zoom = zoom(frameWidth: frameWidth)
            let frameHeight = ceil((height + 0.25) * zoom)
            if frameHeight / zoom < height + 0.75, frameHeight <= floor(pane.height) {
                return Self(size: CGSize(width: frameWidth, height: frameHeight), zoom: zoom)
            }
        }
        let zoom = zoom(frameWidth: largest)
        return Self(size: CGSize(width: largest, height: max(1, ((height + 0.5) * zoom).rounded(.down))), zoom: zoom)
    }

    /// The factor that brings a capture within the pixel limit; 1 if it fits.
    static func captureReduction(pixelWidth: Double, pixelHeight: Double, maximumPixels: Double) -> Double {
        let pixels = pixelWidth * pixelHeight
        guard pixels > maximumPixels else { return 1 }
        // Rounding up to whole pixels must not push the result over the limit.
        return (maximumPixels / pixels).squareRoot() * 0.995
    }
}
