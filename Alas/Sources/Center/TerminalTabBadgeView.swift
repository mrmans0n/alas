import AlasCore
import SwiftUI

/// The program badge beside a terminal tab's icon: an agent's own logo, or
/// a catalogued app's mark on a tile of its brand colour.
struct TerminalTabBadgeView: View {
    let badge: TerminalTabPresence.Badge
    var size: CGFloat = 12

    var body: some View {
        switch badge {
        case .agent(let agent):
            Image(agent.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        case .app(let app):
            if case .logo(let assetName) = app.glyph {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .help(app.displayName)
                    .accessibilityLabel(app.displayName)
            } else {
                TerminalAppTile(app: app, size: size)
            }
        }
    }
}

private struct TerminalAppTile: View {
    let app: TerminalApp
    let size: CGFloat

    var body: some View {
        let tint = Color(hex: app.tintHex)
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(Self.glyphColor(onTintHex: app.tintHex)) }
            .help(app.displayName)
            .accessibilityLabel(app.displayName)
    }

    @ViewBuilder
    private var glyph: some View {
        switch app.glyph {
        case .brand(let assetName), .logo(let assetName):
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size * 0.66, height: size * 0.66)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.6, weight: .semibold))
        }
    }

    /// Black on bright brand colours (Node's yellow-green, Vite's purple
    /// stays white), white everywhere else.
    static func glyphColor(onTintHex hex: String) -> Color {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return .white }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 ? .black : .white
    }
}
