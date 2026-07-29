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

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        let bytes = key.source.utf8.count
        guard bytes > 0 else { return .failed(.empty) }
        guard bytes <= Self.maximumSourceBytes else {
            return .failed(.sourceTooLarge(actualBytes: bytes))
        }
        do {
            let layout = try await Task.detached {
                try MermaidRenderer.layout(key.source)
            }.value
            if let failure = Self.preflightRaster(
                layoutSize: CGSize(width: layout.width, height: layout.height),
                scale: key.scale
            ) {
                return .failed(failure)
            }
            guard let image = try await MermaidRenderer.renderImageAsync(
                source: key.source,
                theme: key.theme.nativeTheme,
                scale: CGFloat(key.scale)
            ) else {
                return .failed(.renderFailed("Renderer returned no image"))
            }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return .failed(.renderFailed("Renderer returned an image without pixels"))
            }
            if let failure = Self.validateRaster(
                width: cg.width,
                height: cg.height
            ) {
                return .failed(failure)
            }
            return .rendered(MermaidRenderedDiagram(
                image: image,
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
