import SwiftUI

/// The files a finished turn changed, as one line in the voice of the activity rows: the
/// chevron lists the files, "Review changes" opens every recorded edit, and each listed file
/// opens only its own.
struct ACPTurnChangesCard: View {
    /// Where the card's caption comes from, and what it is written from.
    struct Caption {
        let store: ACPTurnCaptionStore
        let key: ACPTurnCaptionStore.Key
        let input: () -> ACPTurnCaptionPolicy.Input?
    }

    let changes: ACPTurnChanges
    let caption: Caption?
    /// Nil for transcript hosts without a turn diff tab. Nil path opens all files.
    let onOpenDiff: ((String?) -> Void)?
    /// The caption the session's host wrote, when it runs on another machine.
    var hostCaption: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.acpMarkdownProseMaxWidth) private var proseMaxWidth
    @Environment(\.designScale) private var scale
    @State private var expanded = false
    @State private var hoveredPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changes.files, id: \.path, content: fileRow)
                }
                .padding(.bottom, scale.space[2])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .frame(maxWidth: proseMaxWidth, alignment: .leading)
    }

    private var summary: some View {
        HStack(spacing: scale.space[2]) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: scale.space[2]) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(scale.glyphFont)
                        .foregroundStyle(theme.color("fg-faint"))
                        .frame(width: Self.chevronWidth)
                    ZStack {
                        RoundedRectangle(cornerRadius: scale.radius.small)
                            .fill(theme.color("accent").opacity(0.18))
                        Image(systemName: "doc.on.doc")
                            .font(scale.caption.font(weight: .regular))
                            .foregroundStyle(theme.color("accent"))
                    }
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .accessibilityHidden(true)
                    Text(changes.files.count == 1 ? "Changed 1 file" : "Changed \(changes.files.count) files")
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundStyle(theme.color("fg"))
                        .fixedSize()
                    ACPTurnChangesCounts(added: changes.added, removed: changes.removed)
                        .fixedSize()
                    captionSuffix
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help(expanded ? "Hide the changed files" : "Show the changed files")

            if let onOpenDiff {
                Button("Review changes") { onOpenDiff(nil) }
                    .buttonStyle(ReviewChangesButtonStyle(theme: theme))
                    .fixedSize()
                    .padding(.trailing, scale.space[2])
                    .help("Open all recorded diffs for this turn")
            }
        }
    }

    @ViewBuilder
    private var captionSuffix: some View {
        if let caption {
            StoredCaption(caption: caption, store: caption.store)
        } else {
            CaptionSuffix(text: hostCaption)
        }
    }

    private func fileRow(_ file: ACPTurnChanges.File) -> some View {
        let row = HStack(spacing: scale.space[2]) {
            FileChip(path: file.path, lines: nil, iconSystemName: nil)
            ACPTurnChangesCounts(added: file.added, removed: file.removed)
                .fixedSize()
            Spacer(minLength: scale.space[2])
            if onOpenDiff != nil {
                Text("Open diff")
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(theme.color("accent"))
                    .opacity(hoveredPath == file.path ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        // Lines the chips up under the summary's label, past the chevron and the tile.
        .padding(.leading, scale.space[3] + Self.chevronWidth + Self.tileSize + scale.space[2] * 2)
        .padding(.trailing, scale.space[3]).padding(.vertical, scale.space[1])
        .contentShape(Rectangle())

        return Group {
            if let onOpenDiff {
                Button { onOpenDiff(file.path) } label: { row }
                    .buttonStyle(.plain)
                    .background(hoveredPath == file.path ? theme.color("bg-2").opacity(0.6) : .clear)
                    .onHover { hoveredPath = $0 ? file.path : (hoveredPath == file.path ? nil : hoveredPath) }
                    .help("Open this file's recorded diff")
                    .accessibilityLabel("Open the recorded diff of \(file.path)")
            } else {
                row
            }
        }
    }

    private static let chevronWidth: CGFloat = 12
    private static let tileSize: CGFloat = 18
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
        .font(scale.meta.font(weight: .regular, design: .monospaced))
    }
}

/// The caption this Mac writes for the turn, requested when the card first shows.
private struct StoredCaption: View {
    let caption: ACPTurnChangesCard.Caption
    @ObservedObject var store: ACPTurnCaptionStore

    var body: some View {
        CaptionSuffix(text: store.captions[caption.key])
            .onAppear { store.request(key: caption.key, input: caption.input) }
    }
}

/// "· caption" after the counts, cut to the line it has left.
private struct CaptionSuffix: View {
    let text: String?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        ZStack(alignment: .leading) {
            if let text {
                Text("· \(text)")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: text)
    }
}

private struct ReviewChangesButtonStyle: ButtonStyle {
    let theme: Theme
    @Environment(\.designScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(scale.meta.font(weight: .semibold))
            .padding(.horizontal, scale.space[3])
            .frame(height: 24)
            .background(theme.color("accent").opacity(configuration.isPressed ? 0.78 : 0.95))
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
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
