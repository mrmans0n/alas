import SwiftUI

struct RepoDot: View {
    let color: String   // hex, e.g. "#5fb7c4"
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(Color(hex: color))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255.0
        let g = Double((int >> 8) & 0xff) / 255.0
        let b = Double(int & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
