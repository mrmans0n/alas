import AppKit
import BeautifulMermaid

extension MermaidDiagramTheme {
    var nativeTheme: DiagramTheme {
        DiagramTheme(
            background: BMColor(hex: background),
            foreground: BMColor(hex: foreground),
            line: BMColor(hex: line),
            accent: BMColor(hex: accent),
            muted: BMColor(hex: muted),
            surface: BMColor(hex: surface),
            border: BMColor(hex: border)
        )
    }
}

struct BeautifulMermaidBackend: MermaidRenderingBackend {
    static let maximumSourceBytes = 256 * 1024
    static let maximumDimension = 8_192
    static let maximumPixels = 16_000_000

    static func validateRaster(
        width: Int,
        height: Int
    ) -> MermaidRenderFailure? {
        guard width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width * height <= maximumPixels
        else {
            return .rasterTooLarge(width: width, height: height)
        }
        return nil
    }

    static func preflightRaster(
        layoutSize: CGSize,
        scale: Double
    ) -> MermaidRenderFailure? {
        let width = layoutSize.width * scale
        let height = layoutSize.height * scale
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= Double(Int.max),
              height <= Double(Int.max)
        else {
            return .rasterTooLarge(
                width: maximumDimension + 1,
                height: maximumDimension + 1
            )
        }
        return validateRaster(width: Int(width), height: Int(height))
    }

    /// Rasterizes a prepared diagram into a bitmap context.
    ///
    /// BeautifulMermaid's renderers draw in a top-left origin space, so a raw
    /// `CGContext` has to be flipped first — its own
    /// `MermaidImageRenderer.renderImage` skips that on AppKit (1.0.4) and
    /// hands back vertically mirrored diagrams, which is why we rasterize here
    /// instead of calling it.
    static func rasterize(
        _ prepared: PreparedDiagram,
        scale: CGFloat
    ) -> CGImage? {
        let bounds = prepared.bounds
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0,
              height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        // The renderer paints the theme background over `bounds` itself unless
        // the theme is transparent.
        prepared.render(context, bounds)
        return context.makeImage()
    }

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        let bytes = key.source.utf8.count
        guard bytes > 0 else { return .failed(.empty) }
        guard bytes <= Self.maximumSourceBytes else {
            return .failed(.sourceTooLarge(actualBytes: bytes))
        }
        do {
            let renderer = MermaidImageRenderer(theme: key.theme.nativeTheme)
            guard let prepared = try renderer.prepare(from: key.source) else {
                return .failed(.renderFailed("Renderer returned no layout"))
            }
            if let failure = Self.preflightRaster(
                layoutSize: prepared.bounds.size,
                scale: key.scale
            ) {
                return .failed(failure)
            }
            guard !Task.isCancelled else {
                return .failed(.renderFailed("Mermaid rendering cancelled"))
            }
            guard let cg = Self.rasterize(prepared, scale: CGFloat(key.scale)) else {
                return .failed(.renderFailed("Renderer returned no image"))
            }
            if let failure = Self.validateRaster(
                width: cg.width,
                height: cg.height
            ) {
                return .failed(failure)
            }
            return .rendered(MermaidRenderedDiagram(
                image: NSImage(cgImage: cg, size: prepared.bounds.size),
                pixelSize: CGSize(width: cg.width, height: cg.height),
                byteCost: cg.width * cg.height * 4
            ))
        } catch {
            // BeautifulMermaid 1.0.4 does not expose typed errors for its
            // parser or layout internals. Keep this mapping aligned with its
            // public diagnostic strings when upgrading the dependency.
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("unsupported") {
                return .failed(.unsupported(message))
            }
            if message.localizedCaseInsensitiveContains("parse") {
                return .failed(.parseFailed(message))
            }
            if message.localizedCaseInsensitiveContains("layout") {
                return .failed(.layoutFailed(message))
            }
            return .failed(.renderFailed(message))
        }
    }
}
