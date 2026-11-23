import AppKit
import SwiftUI

/// Square tile with the file-type glyph.
struct FileTypeIconView: View {
    let filename: String
    var size: CGFloat = 18
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        let info = FileTypeIcon.info(for: filename)
        switch info.style {
        case .nerdFont:
            NerdFontGlyphView(symbol: info.symbol, hex: info.hex)
                .frame(width: size, height: size)
        case .text:
            let color = theme.darkMode
                ? Color(hex: info.hex)
                : Color.blend(Color(hex: info.hex), .black, t: FileTypeIcon.lightThemeDarkening)
            Text(info.symbol)
                .font(.custom(FileTypeIcon.nerdFontName, size: fontPx(for: info.symbol)))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: size, height: size)
                .background(color.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                        .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous))
        }
    }

    private func fontPx(for label: String) -> CGFloat {
        let chars = max(1, label.count)
        let scale: CGFloat
        switch chars {
        case 1:  scale = 0.72
        case 2:  scale = 0.60
        default: scale = 0.48  // 3+
        }
        return max(8, (size * scale).rounded())
    }
}

/// Renders a Nerd Font glyph for semantically meaningful folders,
/// falling back to the standard SF Symbol folder icon for generic ones.
struct FolderIconView: View {
    let name: String
    let path: String
    let open: Bool
    let fallbackColor: Color
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let info = FileTypeIcon.folderInfo(name: name, path: path) {
                NerdFontGlyphView(symbol: info.symbol, hex: info.hex)
            } else {
                Icon(name: "folder", size: 11, color: fallbackColor)
            }
        }
        .frame(width: size, height: size)
    }
}

struct NerdFontGlyphView: NSViewRepresentable {
    let symbol: String
    let hex: String

    func makeNSView(context: Context) -> GlyphDrawingView {
        let view = GlyphDrawingView()
        view.symbol = symbol
        view.hex = hex
        return view
    }

    func updateNSView(_ nsView: GlyphDrawingView, context: Context) {
        nsView.symbol = symbol
        nsView.hex = hex
    }
}

final class GlyphDrawingView: NSView {
    var symbol: String = "" {
        didSet { needsDisplay = true }
    }

    var hex: String = "7A8089" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    // The fill resolves per appearance (see `lightThemeDarkening`).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext,
              let path = NerdFontGlyphPath.path(for: symbol) else {
            return
        }

        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset = max(1, min(self.bounds.width, self.bounds.height) * 0.06)
        let target = self.bounds.insetBy(dx: inset, dy: inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale

        context.saveGState()
        let base = NSColor(hex: hex)
        let fill = NSColor.appearanceAware(
            dark: base,
            light: base.blended(withFraction: FileTypeIcon.lightThemeDarkening, of: .black) ?? base
        )
        context.setFillColor(fill.cgColor)
        context.translateBy(
            x: target.midX - scaledWidth / 2 - bounds.minX * scale,
            y: target.midY + scaledHeight / 2 + bounds.minY * scale
        )
        context.scaleBy(x: scale, y: -scale)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xff) / 255.0
        let g = CGFloat((int >> 8) & 0xff) / 255.0
        let b = CGFloat(int & 0xff) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
