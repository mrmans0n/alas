import SwiftUI

/// Inline monospace pill used to mark a file reference inside chat messages
/// (read/edit tool targets, user `@`-mentions, etc.). Visual: rounded rect
/// with a leading glyph, filename in fg, dir in muted, optional line range
/// after a hairline divider.
struct FileChip: View {
    let path: String
    let lines: String?
    let iconSystemName: String?
    @Environment(\.theme) private var theme

    private var name: String { (path as NSString).lastPathComponent }
    private var dir: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    var body: some View {
        HStack(spacing: 6) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .fontWeight(.medium)
                .lineLimit(1)
            if !dir.isEmpty {
                Text("· " + dir)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let lines {
                Rectangle().fill(theme.color("line")).frame(width: 0.5, height: 10)
                Text(lines)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .help(path)
    }
}
