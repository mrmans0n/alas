import SwiftUI

/// The files a finished turn changed, under its answer: one line per file with its line counts,
/// each opening the file's diff where the files are on this Mac.
struct ACPTurnChangesCard: View {
    /// Where the card's caption comes from, and what it is written from.
    struct Caption {
        let store: ACPTurnCaptionStore
        let key: String
        let input: () -> ACPTurnCaptionPolicy.Input?
    }

    let changes: ACPTurnChanges
    let caption: Caption?
    /// Nil when the files live on another machine: the rows only list them.
    let onOpenDiff: ((String) -> Void)?
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
                if let onOpenDiff {
                    Button { onOpenDiff(file.path) } label: { fileRow(file) }
                        .buttonStyle(.plain)
                        .help("Open diff")
                } else {
                    fileRow(file)
                }
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

    private func fileRow(_ file: ACPTurnChanges.File) -> some View {
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

    @ViewBuilder
    private var header: some View {
        if let caption {
            CaptionedHeader(caption: caption, store: caption.store, changes: changes)
        } else {
            CaptionedHeader.countsLine(changes: changes)
        }
    }

    private func counts(added: Int, removed: Int) -> some View {
        ACPTurnChangesCounts(added: added, removed: removed)
    }
}

private struct ACPTurnChangesCounts: View {
    let added: Int
    let removed: Int
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: scale.space[1]) {
            Text("+\(added)").foregroundStyle(theme.color("add"))
            Text("-\(removed)").foregroundStyle(theme.color("del"))
        }
        .font(scale.caption.font(weight: .regular, design: .monospaced))
    }
}

/// The card's first line: "N files changed" with the totals, under the turn's caption once written.
private struct CaptionedHeader: View {
    let caption: ACPTurnChangesCard.Caption
    @ObservedObject var store: ACPTurnCaptionStore
    let changes: ACPTurnChanges
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let text = store.captions[caption.key] {
                Text(text)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(2)
                    .padding(.horizontal, scale.space[3]).padding(.top, scale.space[2])
                    .transition(.opacity)
            }
            Self.countsLine(changes: changes)
        }
        .animation(.easeOut(duration: 0.15), value: store.captions[caption.key])
        .onAppear { store.request(key: caption.key, input: caption.input) }
    }

    static func countsLine(changes: ACPTurnChanges) -> some View {
        CountsLine(changes: changes)
    }

    private struct CountsLine: View {
        let changes: ACPTurnChanges
        @Environment(\.theme) private var theme
        @Environment(\.designScale) private var scale

        var body: some View {
            HStack(spacing: scale.space[2]) {
                Image(systemName: "doc.on.doc")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("accent"))
                Text(changes.files.count == 1 ? "1 file changed" : "\(changes.files.count) files changed")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                ACPTurnChangesCounts(added: changes.added, removed: changes.removed)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[3]).padding(.top, scale.space[2]).padding(.bottom, scale.space[1])
        }
    }
}
