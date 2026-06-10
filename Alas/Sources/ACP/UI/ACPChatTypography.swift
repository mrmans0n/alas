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

    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(appKitFont(size: size)).weight(weight)
    }

    func appKitFont(size: CGFloat? = nil) -> NSFont {
        CenterTypography.resolveCodeFont(
            family: fontFamily,
            size: size ?? baseSize
        )
    }
}
