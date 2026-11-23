import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// One inline chip, drawn as the Mac draws it. The composer and sent
/// messages host it in text attachments; a leading command shows it alone.
struct ChipView: View {
    let model: ChipModel
    /// A reference chip's kind once the host looked it up; the model's until then.
    var references: ReferenceCache?
    /// `.compact` on its own; a chip inside text takes the text's.
    var metrics: ChipMetrics = .compact

    var body: some View {
        content
            .frame(width: ChipStyle.size(of: model, metrics: metrics).width, height: metrics.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch model {
        case .command(let name, let isAlas):
            CappedChip(label: ChipStyle.displayName(name), tint: ChipStyle.commandTint, prism: isAlas, metrics: metrics) {
                Image(systemName: "wand.and.sparkles").font(.system(size: metrics.glyphSize, weight: .semibold))
            }
        case .reference(let reference, let host, let kind):
            let kind = references?.kind(of: reference, host: host) ?? kind
            let side = metrics.referenceGlyph
            CappedChip(label: reference.spelling, tint: ChipStyle.referenceTint(kind), prism: false, metrics: metrics) {
                switch host {
                case .github: GitHubGlyph().fill(style: FillStyle(eoFill: true)).frame(width: side, height: side)
                case .gitlab: GitLabGlyph().fill().frame(width: side, height: side)
                }
            }
        case .mention, .pasted:
            Text(ChipStyle.label(of: model))
                .font(Font(metrics.labelFont))
                .foregroundStyle(Color(ChipStyle.labelColor(ChipStyle.mentionTint)))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(ChipStyle.mentionTint).opacity(0.22))
                .clipShape(.rect(cornerRadius: metrics.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.radius)
                        .strokeBorder(Color(ChipStyle.mentionTint).opacity(0.55), lineWidth: ChipStyle.stroke)
                }
        case .symbol(let name, let kind, let lines):
            SymbolChip(name: name, kind: kind, lines: lines, metrics: metrics)
        }
    }
}

/// The command and reference shape: a solid cap holding a glyph, then the label.
private struct CappedChip<Glyph: View>: View {
    let label: String
    let tint: UIColor
    let prism: Bool
    let metrics: ChipMetrics
    @ViewBuilder let glyph: Glyph

    var body: some View {
        HStack(spacing: 0) {
            glyph
                .foregroundStyle(.white)
                .frame(width: metrics.capWidth, height: metrics.height)
                .background(prism ? Color.white.opacity(0.08) : Color(tint).opacity(0.55))
            Text(label)
                .font(Font(metrics.labelFont))
                .foregroundStyle(prism ? Color.white : Color(ChipStyle.labelColor(tint)))
                .lineLimit(1)
                .padding(.horizontal, metrics.labelPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background {
            if prism { PrismBackground() } else { Color(tint).opacity(0.16) }
        }
        .clipShape(.rect(cornerRadius: metrics.radius))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius)
                .strokeBorder(prism ? Prism.border : Color(tint).opacity(0.6), lineWidth: ChipStyle.stroke)
        }
    }
}

/// The dark base with the prism sweeping across it; still under Reduce Motion.
struct PrismBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let position = Prism.position(at: context.date.timeIntervalSinceReferenceDate, reducedMotion: reduceMotion)
                LinearGradient(gradient: Prism.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: geometry.size.width * (-1.15 + 2.3 * position))
            }
        }
        .background(Prism.base)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A symbol mention: its kind letter on the kind's colour, then its name.
private struct SymbolChip: View {
    let name: String
    let kind: SymbolKind?
    let lines: Int?
    let metrics: ChipMetrics
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = Color(ChipStyle.symbolColor(kind))
        let gap = metrics.symbolGap
        // Spacing only between badge and name, the one gap `ChipStyle.size` counts there.
        HStack(spacing: 0) {
            HStack(spacing: gap) {
                SymbolKindBadge(kind: kind, side: metrics.symbolBadge)
                Text(name)
                    .font(Font(metrics.labelFont))
                    .foregroundStyle(colorScheme == .dark ? color : color.mix(with: .black, by: 0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let lines {
                Text(ChipStyle.lineCount(lines))
                    .font(Font(metrics.countFont))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, gap + 1)
                    .frame(maxHeight: .infinity)
                    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 0.5) }
            }
        }
        .padding(.leading, gap)
        .padding(.trailing, lines == nil ? metrics.labelPadding : 0)
        .background(colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.05))
        .overlay(alignment: .leading) {
            if lines != nil { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .clipShape(.rect(cornerRadius: metrics.radius))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius)
                .strokeBorder(lines != nil ? Color.accentColor.opacity(0.6) : Color(.separator), lineWidth: ChipStyle.stroke)
        }
    }
}

/// A symbol kind's letter on its colour, as the Mac's symbol badges show it.
struct SymbolKindBadge: View {
    let kind: SymbolKind?
    let side: CGFloat

    var body: some View {
        let color = Color(ChipStyle.symbolColor(kind))
        Text(kind?.badgeLetter ?? "?")
            .font(.system(size: side * 0.65, weight: .bold))
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background(color.opacity(0.20), in: .rect(cornerRadius: 3))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ChipView(model: .command(name: "/ship", isAlas: true))
        ChipView(model: .command(name: "/review", isAlas: false))
        ChipView(model: .mention(name: "App.swift"))
        ChipView(model: .pasted(ordinal: 1, text: "a\nb\nc"))
        ChipView(model: .symbol(name: "Runner.run()", kind: .method, lines: 12))
        ChipView(model: .symbol(name: "Runner", kind: .class, lines: nil))
        ChipView(model: .reference(CodeHostReference(spelling: "#12")!, host: .github, kind: .reviewRequest))
        ChipView(model: .reference(CodeHostReference(spelling: "!7")!, host: .gitlab, kind: nil))
    }
    .padding()
}
