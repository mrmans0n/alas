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

/// A turn's recorded edits in the review surface, so they read like any other diff tab:
/// the configured code font, the file rail, and the AppKit scroller.
struct ACPTurnDiffTabView: View {
    let state: ACPTurnDiffTabState
    let appState: AppState
    let worktree: Worktree
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var session: DiffReviewLoadedSession?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed: Bool
    @State private var wrapLines = false
    @State private var showWhitespace = false

    init(state: ACPTurnDiffTabState, appState: AppState, worktree: Worktree) {
        self.state = state
        self.appState = appState
        self.worktree = worktree
        _railCollapsed = State(initialValue: state.files.count <= 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let session {
                DiffReviewSurface(
                    session: session,
                    selectedFileID: $selectedFileID,
                    railCollapsed: $railCollapsed,
                    layoutMode: diffPreferences.layoutMode,
                    wrapLines: diffPreferences.wrapLines,
                    showWhitespace: diffPreferences.showWhitespace,
                    codeFontFamily: appState.config.code.fontFamily,
                    codeFontSize: CGFloat(appState.config.code.fontSize),
                    showsSourceBadges: false,
                    showsRailDisplayControls: true,
                    allowsDraftCommentCreation: false
                )
            } else {
                Spinner()
                    .frame(width: 16, height: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: state.id) {
            let worktreePath = worktree.path
            let worktreeID = worktree.id
            let loaded = await ACPTurnDiffSessionBuilder.build(files: state.files) { path in
                guard DiffOpenFileAvailability.isAvailable(worktreePath: worktreePath, relativePath: path) else {
                    return nil
                }
                return { appState.openFile(relativePath: path, worktreeId: worktreeID) }
            }
            guard !Task.isCancelled else { return }
            session = loaded
            selectedFileID = loaded.summary.files.first?.id
        }
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState, wrapLines: $wrapLines, showWhitespace: $showWhitespace)
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Text("Turn")
                .font(scale.caption.font(weight: .semibold))
                .padding(.horizontal, scale.space[1])
                .padding(.vertical, scale.space[0])
                .background(theme.color("accent").opacity(0.16))
                .foregroundStyle(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            Text("Edits recorded in the transcript")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-dim"))
            Spacer()
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}

/// Builds the review session for a turn's recorded edits.
enum ACPTurnDiffSessionBuilder {
    static let namespace = "turn-diff"

    /// One recorded edit, read back: its hunks, or a note when it has none to show.
    enum LoadedEdit: Equatable, Sendable {
        case diff(ParsedDiff, change: GitFilePatchChange)
        case note(String)
    }

    /// A file's edits merged into one diff.
    struct CombinedFile: Equatable {
        let diff: ParsedDiff
        let status: DiffReviewFileStatus
    }

    @MainActor
    static func build(
        files: [ACPTurnChanges.FileDiff],
        openFile: (String) -> (() -> Void)?
    ) async -> DiffReviewLoadedSession {
        let combined = await withTaskGroup(of: (Int, CombinedFile).self) { group in
            for (index, file) in files.enumerated() {
                group.addTask {
                    var loaded: [LoadedEdit] = []
                    for edit in file.edits { loaded.append(await load(edit)) }
                    return (index, combine(loaded))
                }
            }
            var byIndex: [Int: CombinedFile] = [:]
            for await (index, file) in group { byIndex[index] = file }
            return files.indices.map { byIndex[$0]! }
        }
        let renderable = files.indices.filter { !combined[$0].diff.hunks.isEmpty }
        let models = (try? await DiffDisplayModelBuilder.buildConcurrently(
            renderable.map { (diff: combined[$0].diff, filePath: files[$0].path) }
        )) ?? []
        let modelsByIndex = Dictionary(zip(renderable, models), uniquingKeysWith: { first, _ in first })

        let sections = files.indices.map { index in
            let path = files[index].path
            let file = combined[index]
            let counts = DiffReviewBatchLoading.lineCounts(in: file.diff)
            let model = modelsByIndex[index]
            var section = DiffReviewFileSectionModel(
                summary: DiffReviewFileSummary(
                    path: path, namespace: namespace, groupID: nil, groupTitle: nil, status: file.status,
                    additions: counts.additions, deletions: counts.deletions, isRenderable: model != nil
                ),
                parsedDiff: file.diff,
                displayModel: model,
                placeholderMessage: model == nil ? (file.diff.metadataSummary ?? "Recorded diff unavailable") : nil,
                openFile: openFile(path),
                contextProvider: nil
            )
            // Edits without hunks stay listed next to the ones that have them.
            if model != nil { section.notice = file.diff.metadataSummary }
            return section
        }
        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    /// Each edit's hunks in order; when the file was edited more than once every hunk header says
    /// which edit it belongs to, since their line numbers count from different versions of the file.
    /// Edits without hunks become notes in the metadata summary.
    static func combine(_ edits: [LoadedEdit]) -> CombinedFile {
        var hunks: [ParsedDiff.Hunk] = []
        var notes: [String] = []
        var changes: [GitFilePatchChange] = []
        for (index, edit) in edits.enumerated() {
            let label = edits.count > 1 ? "Edit \(index + 1) of \(edits.count)" : nil
            switch edit {
            case .diff(let diff, let change):
                changes.append(change)
                if diff.hunks.isEmpty {
                    let note = diff.metadataSummary ?? (diff.isBinary ? "Binary file changed" : "No text changes")
                    notes.append(label.map { "\($0): \(note)" } ?? note)
                }
                hunks += diff.hunks.map { hunk in
                    ParsedDiff.Hunk(
                        header: label.map { "\($0) · \(hunk.header)" } ?? hunk.header,
                        oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines
                    )
                }
            case .note(let note):
                notes.append(label.map { "\($0): \(note)" } ?? note)
            }
        }
        let status: DiffReviewFileStatus =
            if changes.first == .added { .added }
            else if changes.last == .deleted { .deleted }
            else if changes.contains(.renamed) { .renamed }
            else if changes.isEmpty { .unknown }
            else { .modified }
        return CombinedFile(
            diff: ParsedDiff(hunks: hunks, metadataSummary: notes.isEmpty ? nil : notes.joined(separator: "\n")),
            status: status
        )
    }

    private nonisolated static func load(_ edit: ACPTurnChanges.RecordedEdit) async -> LoadedEdit {
        let unavailable = LoadedEdit.note("Recorded diff unavailable")
        switch edit {
        case .fileEdit(let write):
            if write.oldText == nil, write.newText.isEmpty, write.added > 0 || write.removed > 0 {
                return unavailable
            }
            guard let diff = try? await ACPDiffGenerator.generate(oldText: write.oldText, newText: write.newText) else {
                return unavailable
            }
            return .diff(diff, change: write.oldText == nil ? .added : .modified)
        case .toolPatch(let patch):
            guard let file = patch.parsed() else { return unavailable }
            return .diff(file.diff, change: file.change)
        }
    }
}
