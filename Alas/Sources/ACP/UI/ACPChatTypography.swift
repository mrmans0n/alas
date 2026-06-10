import AppKit
import SwiftUI

struct ACPChatTypography: Equatable {
    static let `default` = ACPChatTypography(
        fontFamily: "JetBrainsMono Nerd Font",
        fontSize: 13
    )

    let fontFamily: String
    let baseSize: CGFloat

    init(fontFamily: String, fontSize: Int) {
        self.fontFamily = fontFamily
        self.baseSize = CGFloat(max(8, min(64, fontSize)))
    }

    var paragraphSize: CGFloat { baseSize + 0.5 }
    var quoteSize: CGFloat { baseSize }
    var codeSize: CGFloat { max(8, baseSize - 1) }
    var tableBodySize: CGFloat { max(8, baseSize - 1) }
    var tableHeaderSize: CGFloat { max(8, baseSize - 1.5) }
    var labelSize: CGFloat { max(8, baseSize - 3) }

    func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 6
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }

    func swiftUIFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        traits: NSFontTraitMask = []
    ) -> Font {
        Font(appKitFont(size: size, traits: traits)).weight(weight)
    }

    func appKitFont(size: CGFloat? = nil, traits: NSFontTraitMask = []) -> NSFont {
        var font = CenterTypography.resolveCodeFont(
            family: fontFamily,
            size: size ?? baseSize
        )
        guard !traits.isEmpty else { return font }

        if traits.contains(.boldFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        var symbolicTraits = font.fontDescriptor.symbolicTraits
        if traits.contains(.boldFontMask) {
            symbolicTraits.insert(.bold)
        }
        if traits.contains(.italicFontMask) {
            symbolicTraits.insert(.italic)
        }
        let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits)
        guard let traitFont = NSFont(descriptor: descriptor, size: size ?? baseSize)
        else { return font }
        return traitFont
    }
}
