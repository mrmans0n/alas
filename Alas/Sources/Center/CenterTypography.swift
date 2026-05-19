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
}

extension View {
    func centerPanelRowSpacing() -> some View {
        padding(.vertical, CenterTypography.rowVerticalPadding)
    }
}
