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

/// The Mac chips' geometry and colours (`ACPMentionChipMetrics`, `ACPCommandPillStyle`).
enum ChipStyle {
    static let height: CGFloat = 18
    static let capWidth: CGFloat = 18
    static let labelPadding: CGFloat = 6
    static let radius: CGFloat = 5
    static let stroke: CGFloat = 0.75
    static let labelFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
    static let countFont = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let symbolBadge: CGFloat = 13

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
    static func size(of chip: ChipModel) -> CGSize {
        let label = ceil((label(of: chip) as NSString).size(withAttributes: [.font: labelFont]).width)
        let width: CGFloat = switch chip {
        case .command, .reference: capWidth + label + 2 * labelPadding
        case .mention, .pasted: label + 14
        case .symbol(_, _, let lines):
            4 + symbolBadge + 4 + label + labelPadding
                + (lines.map { ceil((lineCount($0) as NSString).size(withAttributes: [.font: countFont]).width) + 10.5 } ?? 0)
        }
        return CGSize(width: width, height: height)
    }

    /// The offset that centres a chip on a line of `font`, as the Mac's `baselineOffset`.
    static func baselineOffset(for font: UIFont) -> CGFloat {
        -((height - font.ascender + font.descender) / 2)
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
