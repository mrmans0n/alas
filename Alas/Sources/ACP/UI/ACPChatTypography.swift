import AppKit
import SwiftUI

struct ACPChatTypography: Equatable {
    static let `default` = ACPChatTypography(
        fontFamily: "",
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
        var font = resolveChatFont(size: size ?? baseSize)
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

    private func resolveChatFont(size: CGFloat) -> NSFont {
        let trimmed = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSFont.systemFont(ofSize: size)
        }

        let manager = NSFontManager.shared
        if let members = manager.availableMembers(ofFontFamily: trimmed),
           !members.isEmpty {
            let regularMember = members.first { row in
                guard row.count > 3 else { return false }
                let rawTraits: UInt
                if let traits = row[3] as? UInt {
                    rawTraits = traits
                } else if let traits = row[3] as? Int {
                    rawTraits = UInt(traits)
                } else {
                    return false
                }
                return NSFontTraitMask(rawValue: rawTraits)
                    .intersection([.boldFontMask, .italicFontMask])
                    .isEmpty
            }
            let chosen = regularMember ?? members.first
            if let name = chosen?.first as? String,
               let font = NSFont(name: name, size: size) {
                return font
            }
        }

        if let font = NSFont(name: trimmed, size: size) {
            return font
        }

        return NSFont.systemFont(ofSize: size)
    }
}
