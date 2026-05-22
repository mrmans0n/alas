import AppKit
import SwiftUI

/// Typography helpers for text-dense surfaces in the central panel.
/// `lineHeightMultiple` is the single source of truth; the SwiftUI row
/// padding and `Text` lineSpacing values are derived so the visual
/// rhythm matches across `NSTextView` and SwiftUI surfaces.
enum CenterTypography {
    static let lineHeightMultiple: CGFloat = 1.15

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }

    static let rowVerticalPadding: CGFloat = 1

    /// SwiftUI `Text` doesn't expose `lineHeightMultiple`, so we convert
    /// `lineHeightMultiple` to an absolute `.lineSpacing` value. The 1.2
    /// factor approximates SF's default line-height-to-point-size ratio.
    static func textLineSpacing(forFontSize size: CGFloat) -> CGFloat {
        (lineHeightMultiple - 1) * size * 1.2
    }

    static func resolveCodeFont(family: String, size: CGFloat) -> NSFont {
        guard !family.isEmpty else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // The picker stores family names (e.g. "JetBrains Mono"), but
        // NSFont(name:size:) requires the PostScript name of a specific
        // face ("JetBrainsMono-Regular"). Walk the family's members and
        // pick the face closest to regular weight (NSFontManager weight 5).
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        if !members.isEmpty {
            let sorted = members.sorted { lhs, rhs in
                let lw = (lhs.count > 2 ? lhs[2] as? Int : nil) ?? 5
                let rw = (rhs.count > 2 ? rhs[2] as? Int : nil) ?? 5
                return abs(lw - 5) < abs(rw - 5)
            }
            if let psName = sorted.first?.first as? String,
               let font = NSFont(name: psName, size: size) {
                return font
            }
        }
        if let font = NSFont(name: family, size: size) { return font }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if let font = NSFont(descriptor: descriptor, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Build a SwiftUI `Font` from the user's code font config, using the
    /// same family-name resolution as the editor's `NSTextView`.
    static func codeFont(family: String, size: CGFloat) -> Font {
        Font(resolveCodeFont(family: family, size: size))
    }
}

extension View {
    func centerPanelRowSpacing() -> some View {
        padding(.vertical, CenterTypography.rowVerticalPadding)
    }
}
