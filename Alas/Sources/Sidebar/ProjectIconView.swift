import AppKit
import SwiftUI

struct ProjectIconView: View {
    enum Size {
        case sidebar
        case picker
        case dialog

        var dimension: CGFloat {
            switch self {
            case .sidebar: 16
            case .picker: 18
            case .dialog: 72
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .sidebar: 4
            case .picker: 5
            case .dialog: 18
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .sidebar: 9.5
            case .picker: 10.5
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
            if let symbolName = icon.symbolName {
                symbolView(symbolName)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        case .emoji:
            if let emoji = icon.emoji, !emoji.isEmpty {
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

    private func labelView(_ label: String) -> some View {
        Text(label)
            .font(.system(size: size.fontSize, weight: .bold))
            .foregroundColor(.white)
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(Color(hex: icon.color))
    }

    private func symbolView(_ name: String) -> some View {
        ZStack {
            Color(hex: icon.color)
            Icon(name: name, size: size.fontSize + 2, color: .white)
        }
    }

    private func emojiView(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: size.fontSize + 2))
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(Color(hex: icon.color))
    }

    private func loadImage() -> NSImage? {
        guard let imagePath = icon.imagePath else { return nil }
        return NSImage(contentsOf: ProjectIconImageStaging.url(for: imagePath))
    }

    nonisolated static func accessibilityLabel(project: ProjectConfig) -> String {
        "\(project.name) project icon"
    }
}
