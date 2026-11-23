import CoreText
import SwiftUI

/// The Mac's file-type icon (`FileTypeIconView`): a Nerd Font glyph in its brand colour, or a tile
/// with the extension for a type it has no glyph for.
struct FileTypeIconGlyph: View {
    let info: FileTypeIcon.Info?
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    init(filename: String, size: CGFloat = 16) {
        info = FileTypeIcon.info(for: filename)
        self.size = size
    }

    /// A folder's glyph, or the plain folder symbol for a folder without one.
    init(folder path: String, size: CGFloat = 16) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        info = FileTypeIcon.folderInfo(name: name, path: path)
        self.size = size
    }

    var body: some View {
        Group {
            if let info, Self.fontLoaded {
                let color = color(info.hex)
                switch info.style {
                case .nerdFont:
                    if let path = NerdFontGlyphPath.path(for: info.symbol) { GlyphShape(glyph: Path(path)).fill(color) }
                case .text:
                    Text(info.symbol)
                        .font(.custom(FileTypeIcon.nerdFontName, size: max(8, size * (info.symbol.count > 2 ? 0.48 : 0.6))))
                        .foregroundStyle(color)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: size, height: size)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            } else {
                Image(systemName: info == nil ? "folder" : "doc").font(.footnote).foregroundStyle(info == nil ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Brand hues vanish on a light background, so they darken there as on the Mac.
    private func color(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x7A8089
        let scale = scheme == .dark ? 1 : 1 - FileTypeIcon.lightThemeDarkening
        func channel(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 * scale }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    /// The bundled subset of the Mac's Nerd Font, registered on first use.
    private static let fontLoaded: Bool = {
        guard let url = Bundle.main.url(forResource: "FileTypeIcons", withExtension: "ttf") else { return false }
        var error: Unmanaged<CFError>?
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()
}

/// A glyph outline fitted, centred and flipped into the frame, as `GlyphDrawingView` draws it.
private struct GlyphShape: Shape {
    let glyph: Path

    func path(in rect: CGRect) -> Path {
        let bounds = glyph.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let target = rect.insetBy(dx: max(1, min(rect.width, rect.height) * 0.06), dy: max(1, min(rect.width, rect.height) * 0.06))
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let transform = CGAffineTransform(translationX: target.midX, y: target.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return glyph.applying(transform)
    }
}
