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

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        let bytes = key.source.utf8.count
        guard bytes > 0 else { return .failed(.empty) }
        guard bytes <= Self.maximumSourceBytes else {
            return .failed(.sourceTooLarge(actualBytes: bytes))
        }
        do {
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
            guard cg.width <= Self.maximumDimension,
                  cg.height <= Self.maximumDimension,
                  cg.width * cg.height <= Self.maximumPixels else {
                return .failed(.rasterTooLarge(width: cg.width, height: cg.height))
            }
            return .rendered(MermaidRenderedDiagram(
                image: image,
                pixelSize: CGSize(width: cg.width, height: cg.height),
                byteCost: cg.width * cg.height * 4
            ))
        } catch {
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
