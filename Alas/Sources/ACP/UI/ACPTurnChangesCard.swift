import SwiftUI

/// The files a finished turn changed, under its answer: one line per file with its line counts,
/// each opening the file's diff where the files are on this Mac.
struct ACPTurnChangesCard: View {
    /// Where the card's caption comes from, and what it is written from.
    struct Caption {
        let store: ACPTurnCaptionStore
        let key: ACPTurnCaptionStore.Key
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

extension ACPTurnChanges {
    /// The files the turn that `answerIndex` ends changed, read from this Mac's transcript.
    static func forAnswer(
        at answerIndex: Int, in messages: [ACPMessage], isTurnActive: Bool, worktreeRoot: String?
    ) -> ACPTurnChanges? {
        guard messages.indices.contains(answerIndex), case .agent = messages[answerIndex] else { return nil }
        return forAnswer(at: answerIndex, count: messages.count, isTurnActive: isTurnActive) { index in
            switch messages[index] {
            case .user: .user
            case .agent: .agent
            case .fileEdit(_, let edit): .fileEdit(.init(path: edit.path, added: edit.added, removed: edit.removed))
            case .toolCall(let call): .toolCallEdits(written(by: call, worktreeRoot: worktreeRoot))
            default: .other
            }
        }
    }

    /// The turn's request and patches, for its caption. File writes become patches of their
    /// changed hunks.
    func captionInput(messages: [ACPMessage], answerIndex: Int, worktreeRoot: String?) -> ACPTurnCaptionPolicy.Input? {
        guard messages.indices.contains(userIndex), userIndex < answerIndex, answerIndex <= messages.count
        else { return nil }
        var request: String?
        if case .user(_, _, let text, _, _, _) = messages[userIndex] { request = text }
        var patches: [String] = []
        for message in messages[(userIndex + 1)..<answerIndex] {
            switch message {
            case .fileEdit(_, let edit):
                patches.append(ACPTurnCaptionPolicy.patch(path: edit.path, old: edit.oldText, new: edit.newText))
            case .toolCall(let call) where !Self.written(by: call, worktreeRoot: worktreeRoot).isEmpty:
                patches += call.diffs.filter { $0.source == .toolCall && $0.isValid }.compactMap(\.patch)
            default:
                break
            }
        }
        return ACPTurnCaptionPolicy.Input(request: request, files: files, patches: patches)
    }
}
