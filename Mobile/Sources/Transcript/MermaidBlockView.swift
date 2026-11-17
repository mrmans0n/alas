import BeautifulMermaid
import SwiftUI
import UIKit

/// A closed Mermaid fence, drawn by the Mac's renderer: fitted to the width, never upscaled, at most
/// 420 pt tall, and opened full screen on a tap. A diagram that cannot be drawn reads as a caption
/// and its source.
struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    /// The last render this view finished, so it shows even if the cache has dropped it since.
    @State private var landed: (key: MermaidRenderer.Key, outcome: MermaidRenderer.Outcome)?
    @State private var presented: Presented?

    private struct Presented: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        let key = MermaidRenderer.Key(source: source, dark: colorScheme == .dark, scale: displayScale)
        let outcome = landed?.key == key ? landed?.outcome : MermaidRenderer.cached(key)
        content(outcome)
            .task(id: key) {
                guard outcome == nil else { return }
                let rendered = await MermaidRenderer.render(key)
                if !Task.isCancelled { landed = (key, rendered) }
            }
            .fullScreenCover(item: $presented) { TranscriptImageViewer(image: $0.image, label: "Mermaid diagram") }
    }

    @ViewBuilder
    private func content(_ outcome: MermaidRenderer.Outcome?) -> some View {
        switch outcome {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                // Capping the width keeps the frame the image's own shape, so a wide strip leaves no gap.
                .frame(maxWidth: min(image.size.width, 420 * image.size.width / image.size.height))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Mermaid diagram")
                .accessibilityAddTraits(.isButton)
                .contentShape(Rectangle())
                .onTapGesture { presented = Presented(image: image) }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't render Mermaid diagram").font(.callout.weight(.semibold))
                CodeBlockView(language: "mermaid", chunks: [CodeChunk(text: source, spans: [])])
            }
        case nil:
            // A stable height until the diagram lands, so the row re-measures once.
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .accessibilityLabel("Rendering Mermaid diagram")
        }
    }
}

/// Draws diagrams off the main actor with the Mac's limits, and keeps the results for reuse.
@MainActor
enum MermaidRenderer {
    struct Key: Hashable {
        let source: String
        let dark: Bool
        let scale: CGFloat
    }

    enum Outcome {
        case image(UIImage)
        case failed
    }

    private nonisolated static let maximumSourceBytes = 256 * 1024
    private nonisolated static let maximumDimension: CGFloat = 8192
    private nonisolated static let maximumPixels: CGFloat = 16_000_000

    // ponytail: unbounded by count; small in practice, an LRU if transcripts grow many diagrams.
    private static var cache: [Key: Outcome] = [:]
    private static var cacheBytes = 0

    static func cached(_ key: Key) -> Outcome? {
        cache[key]
    }

    static func render(_ key: Key) async -> Outcome {
        if let hit = cache[key] { return hit }
        let theme = diagramTheme(ThemeTokens.forScheme(key.dark ? .dark : .light))
        let outcome = await Task.detached(priority: .userInitiated) { draw(key.source, theme: theme, scale: key.scale) }.value
        if case .image(let image) = outcome {
            let bytes = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
            // A full cache starts over rather than tracking recency.
            if cacheBytes + bytes > 64 * 1024 * 1024 {
                cache.removeAll()
                cacheBytes = 0
            }
            cacheBytes += bytes
        }
        cache[key] = outcome
        return outcome
    }

    /// The Mac's transcript diagram colours, opaque as its hex conversion leaves them.
    private static func diagramTheme(_ tokens: ThemeTokens) -> DiagramTheme {
        func color(_ token: String) -> UIColor {
            UIColor(tokens.colors[token] ?? .gray).withAlphaComponent(1)
        }
        return DiagramTheme(background: color("bg-1"), foreground: color("fg"), line: color("line"),
                            accent: color("accent"), muted: color("fg-muted"), surface: color("bg-2"),
                            border: color("line"))
    }

    /// Lays the diagram out first, so one too large to draw fails before its bitmap is allocated.
    /// A wide one drops below the screen's 3x before it fails, down to 1x, so whatever the Mac draws
    /// at 2x draws here too.
    private nonisolated static func draw(_ source: String, theme: DiagramTheme, scale: CGFloat) -> Outcome {
        guard !source.isEmpty, source.utf8.count <= maximumSourceBytes,
              let prepared = try? MermaidImageRenderer(theme: theme).prepare(from: source) else { return .failed }
        let bounds = prepared.bounds
        let width = bounds.width, height = bounds.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .failed }
        let scale = min(scale, maximumDimension / max(width, height), (maximumPixels / (width * height)).squareRoot())
        guard scale >= 1 else { return .failed }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        // The renderer paints the theme background itself. UIKit's context is already top-left
        // origin, so the Mac's flip is not needed here.
        return .image(UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            prepared.render(context.cgContext, bounds)
        })
    }
}
