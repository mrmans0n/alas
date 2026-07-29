import AppKit
import SwiftUI

struct MermaidDiagramBlockView: View {
    let source: String
    let profile: MermaidPresentationProfile
    var service: MermaidRenderService = .shared

    @Environment(\.displayScale) private var displayScale
    @Environment(\.theme) private var theme
    @State private var outcome: MermaidRenderOutcome?
    @State private var showsSource = false

    private var key: MermaidRenderKey {
        MermaidRenderKey(
            source: source,
            theme: MermaidDiagramTheme(theme: theme),
            scale: displayScale,
            profile: profile
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MermaidDiagramBlockHeader(
                showsSource: showsSource,
                toggleSource: { showsSource.toggle() },
                copySource: copySource,
                expand: expand
            )
            MermaidDiagramRenderContent(
                source: source,
                profile: profile,
                outcome: outcome
            )
            if showsSource {
                MermaidDiagramSourceView(source: source)
            }
        }
        .background(theme.color("bg-0").opacity(0.6))
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
        .task(id: key) {
            outcome = nil
            outcome = await service.render(key: key)
        }
    }

    private func copySource() {
        Clipboard.copy(source)
    }

    private func expand() {
        guard let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        MermaidDiagramViewerController.shared.show(
            source: source,
            theme: theme,
            from: hostWindow
        )
    }
}

private struct MermaidDiagramBlockHeader: View {
    let showsSource: Bool
    let toggleSource: () -> Void
    let copySource: () -> Void
    let expand: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text("MERMAID")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer(minLength: 0)
            Button(showsSource ? "Hide source" : "Show source", action: toggleSource)
            Button("Copy", action: copySource)
            Button("Expand", action: expand)
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg-muted"))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(theme.color("bg-2").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5)
        }
    }
}

private struct MermaidDiagramRenderContent: View {
    let source: String
    let profile: MermaidPresentationProfile
    let outcome: MermaidRenderOutcome?

    @Environment(\.theme) private var theme

    var body: some View {
        switch outcome {
        case .rendered(let diagram):
            MermaidFittedDiagram(
                diagram: diagram,
                maxHeight: profile.maxEmbeddedHeight,
                source: source
            )
            .padding(12)
            .frame(maxWidth: .infinity)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't render Mermaid diagram")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.color("fg"))
                Text(failure.mermaidDisplayDiagnostic)
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: profile == .compact ? 72 : 120)
                .accessibilityLabel("Rendering Mermaid diagram")
        }
    }
}

private struct MermaidFittedDiagram: View {
    let diagram: MermaidRenderedDiagram
    let maxHeight: CGFloat
    let source: String

    var body: some View {
        MermaidFittedDiagramLayout(
            intrinsicSize: diagram.image.size,
            maxHeight: maxHeight
        ) {
            Image(nsImage: diagram.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel("Mermaid diagram")
                .accessibilityValue(Text(verbatim: source))
        }
    }
}

private struct MermaidFittedDiagramLayout: Layout {
    let intrinsicSize: CGSize
    let maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        MermaidDiagramLayout.fittedSize(
            intrinsic: intrinsicSize,
            availableWidth: proposal.width ?? intrinsicSize.width,
            maxHeight: maxHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

struct MermaidDiagramSourceView: View {
    let source: String
    var maximumHeight: CGFloat = 220

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: source)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maximumHeight)
        .background(theme.color("bg-1"))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5)
        }
    }
}

extension MermaidRenderFailure {
    var mermaidDisplayDiagnostic: String {
        switch self {
        case .empty:
            return "The diagram source is empty."
        case .sourceTooLarge(let actualBytes):
            return "The diagram source is too large (\(actualBytes) bytes)."
        case .unsupported(let message):
            return Self.sanitized("Unsupported diagram. \(message)")
        case .parseFailed(let message):
            return Self.sanitized("The diagram source could not be parsed. \(message)")
        case .layoutFailed(let message):
            return Self.sanitized("The diagram layout failed. \(message)")
        case .renderFailed(let message):
            return Self.sanitized("The diagram image could not be generated. \(message)")
        case .rasterTooLarge(let width, let height):
            return "The rendered diagram is too large (\(width) × \(height) pixels)."
        }
    }

    private static func sanitized(_ message: String) -> String {
        let oneLine = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let scalars = oneLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        guard cleaned.count > 400 else { return cleaned }
        return "\(cleaned.prefix(399))…"
    }
}
