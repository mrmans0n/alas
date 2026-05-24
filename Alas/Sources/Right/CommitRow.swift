import SwiftUI

struct CommitRow: View {
    let commit: CommitInfo
    let isLast: Bool
    var isHistorical: Bool = false
    let onSelect: () -> Void
    let onCopySHA: () -> Void
    var onCherryPick: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @State private var shaHovering = false
    @State private var pendingCherryPick = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                rail
                VStack(alignment: .leading, spacing: 2) {
                    subjectLine
                    metaLine
                }
                .padding(.bottom, isLast ? 6 : 8)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .copyFeedbackOverlay(message: copyFeedback.message)
        .contextMenu {
            Button("Copy Commit SHA") { copySHA() }
            if onCherryPick != nil {
                Divider()
                Button("Cherry-pick…") { pendingCherryPick = true }
            }
        }
        .confirmationDialog(
            "Cherry-pick commit?",
            isPresented: $pendingCherryPick,
            titleVisibility: .visible
        ) {
            Button("Cherry-pick \(String(commit.sha.prefix(7)))", role: .destructive) {
                onCherryPick?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply this commit to the current branch.")
        }
    }

    private var rail: some View {
        GeometryReader { geo in
            let dotSize: CGFloat = 8
            // Aligned with the vertical center of the subject text (system size 12).
            let dotCenterY: CGFloat = 8
            let bottom: CGFloat = isLast ? dotCenterY + dotSize / 2 : geo.size.height
            Path { p in
                p.move(to: CGPoint(x: 4, y: dotCenterY + dotSize / 2))
                p.addLine(to: CGPoint(x: 4, y: bottom))
            }
            .stroke(theme.color("line"), lineWidth: 1)
            Circle()
                .fill(isHistorical ? theme.color("warn") : theme.color("accent"))
                .frame(width: dotSize, height: dotSize)
                .position(x: 4, y: dotCenterY)
        }
        .frame(width: 8)
    }

    private var subjectLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let tag = commit.conventionalTag {
                Text(tag)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(tagColor(tag))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tagColor(tag).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(commit.subject)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(commit.shortSha)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(shaHovering ? theme.color("accent") : theme.color("fg-faint"))
                .onTapGesture { copySHA() }
                .onHover { hovering in
                    shaHovering = hovering
                }
                .pointingHandCursor()
                .help("Click to copy SHA")
            avatar
            Text(relativeTime(commit.date))
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-faint"))
            Text("· \(commit.filesChanged) file\(commit.filesChanged == 1 ? "" : "s")")
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-faint"))
            if shouldShowChangeSummary(additions: commit.insertions, deletions: commit.deletions) {
                Text("+\(commit.insertions)").foregroundColor(theme.color("add"))
                Text("−\(commit.deletions)").foregroundColor(theme.color("del"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private var avatar: some View {
        Text(commit.authorInitials)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 14, height: 14)
            .background(authorColor(commit.author))
            .clipShape(Circle())
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "feat":     return Color(hex: "61dafb")
        case "fix":      return Color(hex: "cc342d")
        case "perf":     return Color(hex: "e0c33b")
        case "refactor": return Color(hex: "a87fc4")
        case "docs":     return Color(hex: "5a8fc4")
        case "test":     return Color(hex: "7aa86a")
        case "chore":    return Color(hex: "9c7b56")
        case "ci":       return Color(hex: "7a8089")
        case "build":    return Color(hex: "9c8e6e")
        default:         return theme.color("fg-muted")
        }
    }

    /// Deterministic hash → one of a small preset palette.
    private func authorColor(_ author: String) -> Color {
        let palette = ["5fb7c4", "c89d6f", "9789c7", "7aa86a", "cf649a", "e0a04a", "5fa7d6"]
        var hash: UInt64 = 5381
        for byte in author.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Color(hex: palette[Int(hash % UInt64(palette.count))])
    }

    private func copySHA() {
        onCopySHA()
        copyFeedback.show("Copied SHA")
    }
}
