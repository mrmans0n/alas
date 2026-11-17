import AlasHighlight
import SwiftUI

extension OKLCH {
    func toColor() -> Color {
        let rgb = linearSRGB()
        return Color(.sRGBLinear, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.alpha)
    }
}
