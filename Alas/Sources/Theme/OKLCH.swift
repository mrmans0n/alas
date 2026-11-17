import AlasHighlight
import SwiftUI

extension OKLCH {
    func toColor() -> Color {
        let rgb = linearSRGB()
        return Color(.sRGBLinear, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: rgb.a)
    }
}
