import SwiftUI

/// The files a finished turn changed, under its answer: one line per file with its line counts,
/// each opening the file's diff.
struct ACPTurnChangesCard: View {
    let changes: ACPTurnChanges
    let onOpenDiff: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.acpMarkdownProseMaxWidth) private var proseMaxWidth
    @Environment(\.designScale) private var scale
    @State private var showsAll = false

    /// More files than this fold behind a "Show more" line.
    static let collapsedFileCount = 5

    private var visibleFiles: ArraySlice<ACPTurnChanges.File> {
        showsAll ? changes.files[...] : changes.files.prefix(Self.collapsedFileCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(visibleFiles, id: \.path) { file in
                Button { onOpenDiff(file.path) } label: {
                    HStack(spacing: scale.space[2]) {
                        Text(file.path)
                            .font(scale.meta.font(weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.color("fg"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: scale.space[2])
                        counts(added: file.added, removed: file.removed)
                    }
                    .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[1])
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open diff")
            }
            let hidden = changes.files.count - visibleFiles.count
            if hidden > 0 {
                Button("Show \(hidden) more") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(theme.color("accent"))
                    .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[1])
            }
        }
        .padding(.bottom, scale.space[1])
        .background(theme.color("bg-2").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .frame(maxWidth: proseMaxWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "doc.on.doc")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("accent"))
            Text(changes.files.count == 1 ? "1 file changed" : "\(changes.files.count) files changed")
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            counts(added: changes.added, removed: changes.removed)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[3]).padding(.top, scale.space[2]).padding(.bottom, scale.space[1])
    }

    private func counts(added: Int, removed: Int) -> some View {
        HStack(spacing: scale.space[1]) {
            Text("+\(added)").foregroundStyle(theme.color("add"))
            Text("-\(removed)").foregroundStyle(theme.color("del"))
        }
        .font(scale.caption.font(weight: .regular, design: .monospaced))
    }
}
