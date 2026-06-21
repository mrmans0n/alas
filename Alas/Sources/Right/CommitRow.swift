import SwiftUI

struct CommitRow: View {
    let commit: CommitInfo
    let isLast: Bool
    var isHistorical: Bool = false
    let onSelect: () -> Void
    let onCopySHA: () -> Void
    var onCopyMessage: (() -> Void)? = nil
    var onOpenRemote: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onCherryPick: (() -> Void)? = nil
    var onRevert: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @State private var shaHovering = false
    @State private var pendingCherryPick = false
    @State private var pendingRevert = false

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
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .copyFeedbackOverlay(message: copyFeedback.message)
        .contextMenu {
            if let onEdit {
                Button("Edit Commit...") { onEdit() }
                Divider()
            }
            Button("Copy Commit SHA") { copySHA() }
            Button("Copy Commit Message") { copyMessage() }
            if let onOpenRemote {
                Button("Open Commit on Remote") { onOpenRemote() }
            }
            if onCherryPick != nil {
                Divider()
                Button("Cherry-pick…") { pendingCherryPick = true }
            }
            if onRevert != nil {
                Divider()
                Button("Revert Commit…", role: .destructive) { pendingRevert = true }
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
        .confirmationDialog(
            "Revert commit?",
            isPresented: $pendingRevert,
            titleVisibility: .visible
        ) {
            Button("Revert \(String(commit.sha.prefix(7)))", role: .destructive) {
                onRevert?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new commit that reverses this commit.")
        }
    }

    private var rail: some View {
        GeometryReader { geo in
            let dotSize: CGFloat = 8
            let outerHalo: CGFloat = 14
            let dotCenterY: CGFloat = 8
            let centerX: CGFloat = 7
            let lineTop = dotCenterY + dotSize / 2 + 2
            let lineBottom: CGFloat = isLast ? lineTop : geo.size.height

            // Vertical gradient line (only when not last)
            if !isLast {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.color("accent-glow"),
                                theme.color("accent-glow-soft").opacity(0.5),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: max(0, lineBottom - lineTop))
                    .position(x: centerX, y: lineTop + max(0, lineBottom - lineTop) / 2)
            }

            // Outer halo ring
            Circle()
                .stroke(theme.color("accent-glow-soft"), lineWidth: 2)
                .frame(width: outerHalo, height: outerHalo)
                .position(x: centerX, y: dotCenterY)

            // Inner colored ring + bg-1 fill (hole-punch look)
            Circle()
                .fill(theme.color("bg-1"))
                .overlay(
                    Circle()
                        .stroke(isHistorical ? theme.color("warn") : theme.color("accent"), lineWidth: 1.5)
                )
                .frame(width: dotSize, height: dotSize)
                .position(x: centerX, y: dotCenterY)
        }
        .frame(width: 14)
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

    private func copyMessage() {
        if let onCopyMessage {
            onCopyMessage()
        } else {
            Clipboard.copy(commit.fullMessage)
        }
        copyFeedback.show("Copied message")
    }
}
