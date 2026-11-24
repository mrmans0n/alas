import SwiftUI

struct ACPTurnDiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let filePath: String?
    let files: [ACPTurnChanges.FileDiff]

    var title: String {
        filePath.map { "\(($0 as NSString).lastPathComponent) (turn)" } ?? "Turn Changes"
    }

    init(sessionID: String, answerID: String, filePath: String?, files: [ACPTurnChanges.FileDiff]) {
        id = "turn-diff:\(sessionID):\(answerID):\(filePath ?? "")"
        self.filePath = filePath
        self.files = files
    }
}

struct ACPTurnDiffTabView: View {
    let state: ACPTurnDiffTabState
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scale.space[2]) {
                Label("Recorded Turn Diff", systemImage: "clock.arrow.circlepath")
                    .font(scale.meta.font(weight: .semibold))
                Text(state.files.count == 1 ? "1 file" : "\(state.files.count) files")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
                Spacer()
            }
            .padding(.horizontal, scale.space[4]).padding(.vertical, scale.space[2])
            .background(theme.color("bg-2"))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.files) { file in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: file.path)
                                .font(scale.meta.font(weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(file.path)
                                .padding(.horizontal, scale.space[4]).padding(.vertical, scale.space[2])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.color("bg-2"))
                                .accessibilityAddTraits(.isHeader)
                            ForEach(file.edits.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 0) {
                                    if file.edits.count > 1 {
                                        TurnDiffNote(text: "Edit \(index + 1) of \(file.edits.count)")
                                    }
                                    RecordedEditDiff(path: file.path, edit: file.edits[index])
                                }
                            }
                            if file.edits.isEmpty {
                                TurnDiffNote(text: "Recorded diff unavailable")
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(theme.color("fg"))
        .background(theme.color("bg-1"))
    }
}

private struct RecordedEditDiff: View {
    let path: String
    let edit: ACPTurnChanges.RecordedEdit
    @Environment(\.designScale) private var scale
    @State private var result: Result?

    private enum Result: Sendable {
        case diff(ParsedDiff)
        case unavailable
    }

    var body: some View {
        Group {
            switch result {
            case nil:
                ProgressView().controlSize(.small)
                    .padding(scale.space[2])
            case .diff(let diff) where !diff.hunks.isEmpty:
                InlineDiffView(diff: diff, relativePath: path, maxLines: .max, onShowAll: nil)
            case .diff(let diff):
                TurnDiffNote(text: diff.metadataSummary ?? (diff.isBinary ? "Binary file changed" : "No text changes"))
            case .unavailable:
                TurnDiffNote(text: "Recorded diff unavailable")
            }
        }
        .task {
            guard result == nil else { return }
            let loaded = await Self.load(edit)
            guard !Task.isCancelled else { return }
            result = loaded
        }
    }

    private nonisolated static func load(_ edit: ACPTurnChanges.RecordedEdit) async -> Result {
        switch edit {
        case .fileEdit(let write):
            if write.oldText == nil, write.newText.isEmpty, write.added > 0 || write.removed > 0 {
                return .unavailable
            }
            guard let diff = try? await ACPDiffGenerator.generate(oldText: write.oldText, newText: write.newText) else {
                return .unavailable
            }
            return .diff(diff)
        case .toolPatch(let patch):
            guard let file = patch.parsed() else { return .unavailable }
            return .diff(file.diff)
        }
    }
}

private struct TurnDiffNote: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Text(text)
            .font(scale.metaFont)
            .foregroundStyle(theme.color("fg-dim"))
            .padding(.horizontal, scale.space[4]).padding(.vertical, scale.space[2])
    }
}
