import AlasHighlight
import AlasRemoteKit
import SwiftUI
import UIKit

/// What one inline chip shows, in the composer and in sent messages.
enum ChipModel: Equatable {
    /// `isAlas` draws the prism: a command Alas runs itself, such as `/ship`.
    case command(name: String, isAlas: Bool)
    /// A file, folder or session mention, labelled `@name`.
    case mention(name: String)
    /// A symbol mention: its kind badge and name, with the line count when code went along.
    case symbol(name: String, kind: SymbolKind?, lines: Int?)
    case reference(CodeHostReference, host: CodeHostKind, kind: CodeHostReferenceSummary.Kind?)
    case pasted(ordinal: Int, text: String)

    var accessibilityLabel: String {
        switch self {
        case .command(let name, _): "Command \(ChipStyle.displayName(name))"
        case .mention(let name): "Mention \(name)"
        case .symbol(let name, _, _): "Symbol \(name)"
        case .reference(let reference, _, let kind):
            "\(kind == .issue ? "Issue" : kind == .reviewRequest ? "Pull request" : "Reference") \(reference.spelling)"
        case .pasted(let ordinal, let text): ACPPastedTextPolicy.label(ordinal: ordinal, content: text)
        }
    }
}

/// A chip's geometry, from the Mac chips' (`ACPMentionChipMetrics`):
/// `compact` is the Mac's size, for a chip shown on its own; a chip inside
/// text is sized from that text's font so it grows with Dynamic Type.
struct ChipMetrics: Equatable {
    let height: CGFloat
    let capWidth: CGFloat
    let labelPadding: CGFloat
    let radius: CGFloat
    let glyphSize: CGFloat
    let referenceGlyph: CGFloat
    let symbolBadge: CGFloat
    let labelFont: UIFont
    let countFont: UIFont

    static let compact = ChipMetrics(label: 11.5, height: 18)

    /// A chip inside text set in `font`: its label a little smaller than the
    /// text, the chip a little taller than the text's line.
    init(textFont font: UIFont) {
        self.init(label: (font.pointSize * 0.85 * 2).rounded() / 2, height: (font.pointSize * 1.25).rounded())
    }

    private init(label: CGFloat, height: CGFloat) {
        let scale = label / 11.5
        self.height = height
        capWidth = height
        labelPadding = (6 * scale).rounded()
        radius = (5 * scale).rounded()
        glyphSize = 9 * scale
        referenceGlyph = 10 * scale
        symbolBadge = (13 * scale).rounded()
        labelFont = .monospacedSystemFont(ofSize: label, weight: .medium)
        countFont = .monospacedSystemFont(ofSize: 9.5 * scale, weight: .regular)
    }

    /// Distance from the chip's bottom edge up to its label's baseline, with
    /// the label centred in the chip. UIKit's descender is negative.
    var labelBaselineInset: CGFloat {
        (height - labelFont.ascender - labelFont.descender) / 2
    }

    /// Where the chip's bottom edge sits against the text baseline, so its
    /// label shares the surrounding text's baseline, as on the Mac.
    var baselineOffset: CGFloat { -labelBaselineInset }

    /// The symbol chip's inset and the space around its badge and count.
    var symbolGap: CGFloat { (4 * labelFont.pointSize / 11.5).rounded() }
}

/// The Mac chips' colours (`ACPCommandPillStyle`) and labels.
enum ChipStyle {
    static let stroke: CGFloat = 0.75
    /// Labels outside a chip, such as a pasted card's title.
    static let labelFont = ChipMetrics.compact.labelFont
    /// Corner radius for chip-like shapes outside text.
    static let radius = ChipMetrics.compact.radius

    static let commandTint = UIColor.systemPurple
    static let mentionTint = UIColor.tintColor

    static func displayName(_ command: String) -> String {
        command.hasPrefix("/") ? String(command.dropFirst()) : command
    }

    static func label(of chip: ChipModel) -> String {
        switch chip {
        case .command(let name, _): displayName(name)
        case .mention(let name): "@" + name
        case .symbol(let name, _, _): name
        case .reference(let reference, _, _): reference.spelling
        case .pasted(let ordinal, let text): ACPPastedTextPolicy.label(ordinal: ordinal, content: text)
        }
    }

    static func referenceTint(_ kind: CodeHostReferenceSummary.Kind?) -> UIColor {
        switch kind {
        case .reviewRequest: .systemGreen
        case .issue: .systemOrange
        case nil: .systemGray
        }
    }

    /// The tint lightened toward white in dark mode and darkened toward black
    /// in light mode, as the Mac's `chipLabelColor`.
    static func labelColor(_ tint: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = tint.resolvedColor(with: traits)
            let dark = traits.userInterfaceStyle == .dark
            return resolved.mixed(with: dark ? .white : .black, by: dark ? 0.55 : 0.45)
        }
    }

    static func lineCount(_ lines: Int) -> String {
        lines >= 400 ? "400+ lines" : lines == 1 ? "1 line" : "\(lines) lines"
    }

    /// The width a chip lays out at, so a text attachment reserves exactly
    /// what the SwiftUI view draws.
    static func size(of chip: ChipModel, metrics m: ChipMetrics = .compact) -> CGSize {
        let label = ceil((label(of: chip) as NSString).size(withAttributes: [.font: m.labelFont]).width)
        let gap = m.symbolGap
        let width: CGFloat = switch chip {
        case .command, .reference: m.capWidth + label + 2 * m.labelPadding
        case .mention, .pasted: label + 2 * (m.labelPadding + 1)
        case .symbol(_, _, let lines):
            gap + m.symbolBadge + gap + label + m.labelPadding
                + (lines.map { ceil((lineCount($0) as NSString).size(withAttributes: [.font: m.countFont]).width) + 2 * gap + 2.5 } ?? 0)
        }
        return CGSize(width: width, height: m.height)
    }

    /// Symbol kind colours from the Mac's symbol chips.
    static func symbolColor(_ kind: SymbolKind?) -> UIColor {
        switch kind {
        case .class, .interface, .module, .type: UIColor(red: 0.77, green: 0.65, blue: 1.0, alpha: 1)
        case .struct, .enum: UIColor(red: 0.61, green: 0.88, blue: 0.54, alpha: 1)
        case .function, .method, .macro: UIColor(red: 0.36, green: 0.85, blue: 1.0, alpha: 1)
        case .property, .constant: UIColor(red: 1.0, green: 0.77, blue: 0.42, alpha: 1)
        case nil: .secondaryLabel
        }
    }
}

/// The Alas prism: a gradient sweeping across the chip every 4.5 s.
enum Prism {
    static let base = Color(red: 0.145, green: 0.137, blue: 0.188)
    static let border = Color(red: 0.635, green: 0.569, blue: 0.871).opacity(0.6)
    static let gradient = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: Color(red: 0.443, green: 0.612, blue: 1).opacity(0.35), location: 0.25),
        .init(color: Color(red: 0.804, green: 0.514, blue: 0.929).opacity(0.55), location: 0.43),
        .init(color: Color(red: 1, green: 0.702, blue: 0.831).opacity(0.35), location: 0.57),
        .init(color: Color(red: 0.553, green: 0.945, blue: 0.882).opacity(0.35), location: 0.75),
        .init(color: .clear, location: 1),
    ])

    /// Where the sweep is, 0…1: a smoothstep over the middle of each period.
    static func position(at time: TimeInterval, reducedMotion: Bool) -> CGFloat {
        guard !reducedMotion else { return 0.5 }
        let phase = time.truncatingRemainder(dividingBy: 4.5) / 4.5
        let progress = min(1, max(0, (phase - 0.15) / 0.6))
        return CGFloat(progress * progress * (3 - 2 * progress))
    }
}

/// Reads the parts of an `alas-symbol` mention URI a chip shows.
enum SymbolMentionURI {
    static func kind(of uri: String) -> SymbolKind? {
        query(uri)["kind"].flatMap(SymbolKind.init(rawValue:))
    }

    /// Lines of code the mention sends along, or nil without code.
    static func includedLines(of uri: String) -> Int? {
        let values = query(uri)
        guard values["code"] == "1", let start = values["start"].flatMap(Int.init),
              let end = values["end"].flatMap(Int.init), end >= start else { return nil }
        return end - start + 1
    }

    private static func query(_ uri: String) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(string: uri)?.queryItems ?? [] { values[item.name] = item.value }
        return values
    }
}

private extension UIColor {
    func mixed(with other: UIColor, by amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1)
    }
}
