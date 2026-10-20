import AppKit
import SwiftUI

struct ProjectIconView: View {
    enum Size {
        case sidebar
        /// E1's repo-header tile. Separate from `.sidebar` so the five
        /// non-sidebar callers of that case keep their 16px icons.
        case repoHeader
        case picker
        case overview
        case dialog

        var dimension: CGFloat {
            switch self {
            case .sidebar: 16
            case .repoHeader: 19
            case .picker: 18
            case .overview: 52
            case .dialog: 72
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .sidebar: 4
            case .repoHeader: 5
            case .picker: 5
            case .overview: 13
            case .dialog: 18
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .sidebar: 9.5
            case .repoHeader: 9.5
            case .picker: 10.5
            case .overview: 20
            case .dialog: 26
            }
        }
    }

    let icon: ProjectIcon
    let fallbackName: String
    var size: Size = .sidebar

    var body: some View {
        content
            .frame(width: size.dimension, height: size.dimension)
            .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch icon.mode {
        case .letter:
            labelView(ProjectIcon.sanitizedLabel(icon.label) ?? ProjectIcon.fallbackLabel(projectName: fallbackName))
        case .symbol:
            if let symbolName = icon.symbolName, Self.canRenderSymbol(symbolName) {
                symbolView(symbolName)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        case .emoji:
            if let emoji = Self.renderableEmoji(icon.emoji) {
                emojiView(emoji)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        case .image:
            if let image = loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.dimension, height: size.dimension)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        }
    }

    /// The squircle fill. Transparent icons drop it and tint the glyph instead.
    @ViewBuilder
    private var background: some View {
        if icon.transparentBackground {
            Color.clear
        } else if let gradient = icon.gradient {
            ProjectIconGradientFill(gradient: gradient)
        } else {
            Color(hex: icon.color)
        }
    }

    /// White reads well on the filled squircle; without a fill the glyph has to
    /// carry the color itself.
    private var glyphColor: Color {
        icon.transparentBackground ? Color(hex: icon.color) : .white
    }

    private func labelView(_ label: String) -> some View {
        Text(label)
            .font(.system(size: size.fontSize, weight: .bold))
            .foregroundColor(glyphColor)
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(background)
    }

    private func symbolView(_ name: String) -> some View {
        ZStack {
            background
            Icon(name: name, size: size.fontSize + 2, color: glyphColor)
        }
    }

    private func emojiView(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: size.fontSize + 2))
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(background)
    }

    private func loadImage() -> NSImage? {
        guard let imagePath = icon.imagePath else { return nil }
        return NSImage(contentsOf: ProjectIconImageStaging.url(for: imagePath))
    }

    nonisolated static func accessibilityLabel(project: ProjectConfig) -> String {
        "\(project.name) project icon"
    }

    @MainActor
    static func canRenderSymbol(_ name: String) -> Bool {
        if Icon.rendersCustomGlyph(for: name) { return true }
        return NSImage(systemSymbolName: Icon.symbol(for: name), accessibilityDescription: nil) != nil
    }

    nonisolated static func renderableEmoji(_ raw: String?) -> String? {
        guard let value = ProjectIcon.sanitizedNonEmpty(raw),
              value.count == 1,
              EmojiIcon.sanitized(value) == value
        else {
            return nil
        }
        return value
    }
}

/// Paints a `ProjectIconGradient` across whatever frame it is given, so the
/// same view fills the squircle and the editor's swatches.
struct ProjectIconGradientFill: View {
    let gradient: ProjectIconGradient

    var body: some View {
        let colors = gradient.stops.map { Color(hex: $0) }
        switch gradient.direction {
        case .radial:
            GeometryReader { proxy in
                RadialGradient(
                    colors: colors,
                    center: UnitPoint(x: 0.3, y: 0.3),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height)
                )
            }
        case .down:
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        case .right:
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        case .downRight:
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .upRight:
            LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing)
        }
    }
}

/// Starter gradients for the icon editor, picked to keep the white glyph
/// readable at sidebar size.
struct ProjectIconGradientPreset {
    let name: String
    let gradient: ProjectIconGradient

    private init(_ name: String, _ stops: [String], _ direction: ProjectIconGradient.Direction = .downRight) {
        self.name = name
        // Presets are literals; a typo here should fail loudly in debug.
        self.gradient = ProjectIconGradient(stops: stops, direction: direction)!
    }

    /// Two tones of one hue, close to the solid palette.
    static let subtle: [ProjectIconGradientPreset] = [
        .init("Teal", ["#6cc4d0", "#3f8f9c"]),
        .init("Indigo", ["#8a96e6", "#5961c2"]),
        .init("Sage", ["#8ccb84", "#4f9a5a"]),
        .init("Amber", ["#e8b46a", "#c27a3a"]),
        .init("Rose", ["#e48a96", "#b85571"]),
        .init("Slate", ["#8e97a8", "#4f5768"]),
    ]

    static let bold: [ProjectIconGradientPreset] = [
        .init("Sunset", ["#f12711", "#f5af19"]),
        .init("Peach", ["#ff7e5f", "#e8894a"]),
        .init("Flamingo", ["#ee0979", "#ff6a00"]),
        .init("Candy", ["#f093fb", "#f5576c"], .radial),
        .init("Neon", ["#fc466b", "#3f5efb"]),
        .init("Grape", ["#8e2de2", "#4a00e0"]),
        .init("Aurora", ["#00c9a7", "#845ec2"]),
        .init("Lagoon", ["#43e97b", "#2bb5c4", "#3f6fe0"]),
        .init("Mint", ["#11998e", "#38ef7d"], .upRight),
        .init("Ocean", ["#2193b0", "#6dd5ed"], .upRight),
        .init("Deep Sea", ["#0f2027", "#203a43", "#2c5364"], .down),
        .init("Ember", ["#cb2d3e", "#ef473a"]),
    ]
}
