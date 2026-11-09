import SwiftUI

/// Inline monospace pill used to mark a file reference inside chat messages
/// (read/edit tool targets, user `@`-mentions, etc.). Visual: rounded rect
/// with a leading glyph, filename in fg, dir in muted, optional line range
/// after a hairline divider.
struct FileChip: View {
    @Environment(\.designScale) private var scale
    let path: String
    let lines: String?
    let iconSystemName: String?
    var action: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    private var name: String { (path as NSString).lastPathComponent }
    private var dir: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: scale.space[2]) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(scale.glyphFont)
                    .foregroundStyle(theme.color("fg-faint"))
            }
            Text(name)
                .font(scale.meta.font(design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .fontWeight(.medium)
                .lineLimit(1)
            if !dir.isEmpty {
                Text("· " + dir)
                    .font(scale.meta.font(design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let lines {
                Rectangle().fill(theme.color("line")).frame(width: 0.5, height: 10)
                Text(lines)
                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 20)
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .help(path)
    }
}
