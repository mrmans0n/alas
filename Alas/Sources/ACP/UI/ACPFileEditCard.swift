import SwiftUI

struct ACPFileEditCard: View {
    let edit: ACPMessage.FileEdit
    let onOpenDiff: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var expanded = false

    private var hasDiffContent: Bool {
        edit.oldText != nil || edit.newText != ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, hasDiffContent {
                diffPanel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: {
                if hasDiffContent {
                    withAnimation(.easeOut(duration: 0.12)) {
                        expanded.toggle()
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.color("fg-faint"))
                        .frame(width: 12)
                        .opacity(hasDiffContent ? 1 : 0.3)

                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.color("accent").opacity(0.18))
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("accent"))
                    }
                    .frame(width: 18, height: 18)

                    Text("Edit")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("accent"))

                    FileChip(path: edit.path, lines: nil, iconSystemName: nil)

                    Text("+\(edit.added) -\(edit.removed)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))

                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.color("bg-1").opacity(0.5))
            }
            .buttonStyle(.plain)

            Button("Open diff") {
                onOpenDiff(edit.path)
            }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.color("accent"))
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(theme.color("bg-1").opacity(0.5))
    }

    @ViewBuilder
    private var diffPanel: some View {
        _InlineDiffPanel(
            oldText: edit.oldText,
            newText: edit.newText,
            relativePath: edit.path,
            onShowAll: onOpenDiff
        )
    }
}

private struct _InlineDiffPanel: View {
    let oldText: String?
    let newText: String
    let relativePath: String
    let onShowAll: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var diff: ParsedDiff?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .padding(12)
                .background(theme.color("bg-2"))
            } else if let diff, !diff.hunks.isEmpty {
                InlineDiffView(
                    diff: diff,
                    relativePath: relativePath,
                    maxLines: 15,
                    onShowAll: { onShowAll(relativePath) }
                )
            } else {
                Text("No changes")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-dim"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(theme.color("bg-2"))
            }
        }
        .overlay(Divider().opacity(0.5), alignment: .top)
        .task {
            loading = true
            diff = try? await ACPDiffGenerator.generate(
                oldText: oldText,
                newText: newText
            )
            loading = false
        }
    }
}
