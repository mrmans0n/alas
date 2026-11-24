import SwiftUI

extension FocusedValues {
    @Entry var reviewFind: DiffReviewFindRequest?
}

@MainActor
@Observable
final class DiffReviewFindRequest {
    struct Invocation: Equatable {
        let action: EditorFindRequest
        let generation: Int
    }

    private(set) var invocation: Invocation?

    func perform(_ action: EditorFindRequest) {
        invocation = Invocation(action: action, generation: (invocation?.generation ?? 0) + 1)
    }
}

struct DiffReviewFindMatch: Equatable, Sendable {
    let fileID: DiffReviewFileID
    let side: DiffReviewInlineFeedbackSide
    let line: Int
    let range: NSRange
    let collapsedRowID: String?
}

struct DiffReviewFindInput: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let id: DiffReviewFileID
        let model: DiffDisplayModel
    }

    let query: String
    let caseSensitive: Bool
    let files: [File]

    @concurrent
    func matches() async -> [DiffReviewFindMatch] {
        guard !query.isEmpty else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var result: [DiffReviewFindMatch] = []

        func append(_ line: DiffDisplayLine?, side: DiffReviewInlineFeedbackSide, fileID: DiffReviewFileID, collapsedRowID: String?) {
            guard let line, let number = line.lineNumber else { return }
            let text = line.text as NSString
            let length = text.length
            var start = 0
            while start < length {
                let range = text.range(of: query, options: options, range: NSRange(location: start, length: length - start))
                guard range.location != NSNotFound else { break }
                result.append(.init(fileID: fileID, side: side, line: number, range: range, collapsedRowID: collapsedRowID))
                start = NSMaxRange(range)
            }
        }

        func append(_ row: DiffDisplayRow, fileID: DiffReviewFileID, collapsedRowID: String? = nil) {
            if row.kind == .collapsed {
                for child in row.collapsedRows {
                    if Task.isCancelled { return }
                    append(child, fileID: fileID, collapsedRowID: row.id)
                }
                return
            }
            // Paired context is the same code on both sides, so count it once.
            if row.new == nil || (row.kind != .context && row.kind != .expandedContext) {
                append(row.old, side: .old, fileID: fileID, collapsedRowID: collapsedRowID)
            }
            append(row.new, side: .new, fileID: fileID, collapsedRowID: collapsedRowID)
        }

        for file in files {
            for group in file.model.groups {
                for row in group.rows {
                    if Task.isCancelled { return [] }
                    append(row, fileID: file.id)
                }
            }
        }
        return result
    }
}

struct DiffReviewFindBar: View {
    let request: DiffReviewFindRequest
    let session: DiffReviewLoadedSession
    let selectedFileID: DiffReviewFileID?
    let reveal: (DiffReviewFindMatch) -> Void

    @State private var isPresented = false
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var matches: [DiffReviewFindMatch] = []
    @State private var selectedIndex: Int?
    @State private var startAtLastMatch = false
    @State private var lastSearch: DiffReviewFindInput?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isPresented {
                let input = DiffReviewFindInput(
                    query: query,
                    caseSensitive: caseSensitive,
                    files: query.isEmpty ? [] : session.files.compactMap { file in
                        guard file.imageProvider == nil, let model = file.displayModel else { return nil }
                        return .init(id: file.id, model: model)
                    }
                )
                EditorFindBarView(
                    findText: $query,
                    isCaseSensitive: $caseSensitive,
                    findFieldFocused: $focused,
                    statusText: statusText(for: input),
                    onFind: navigate,
                    onDone: close
                )
                .onAppear { focused = true }
                .task(id: input) { await refresh(input) }
            }
        }
        .onChange(of: request.invocation) { _, invocation in
            switch invocation?.action {
            case .showFind:
                isPresented = true
                focused = true
            case .findNext:
                navigate(.next)
            case .findPrevious:
                navigate(.previous)
            case .showReplace, nil:
                break
            }
        }
    }

    private func statusText(for input: DiffReviewFindInput) -> String {
        guard !query.isEmpty else { return "" }
        guard input == lastSearch else { return "Searching…" }
        guard let selectedIndex else { return "No matches" }
        return "\(selectedIndex + 1) of \(matches.count)"
    }

    private func refresh(_ input: DiffReviewFindInput) async {
        let updated = await input.matches()
        guard !Task.isCancelled else { return }
        lastSearch = input
        let previous = selectedIndex.map { matches[$0] }
        matches = updated
        guard !updated.isEmpty else {
            selectedIndex = nil
            startAtLastMatch = false
            return
        }
        if let previous, let retainedIndex = updated.firstIndex(of: previous) {
            selectedIndex = retainedIndex
        } else {
            let index = startAtLastMatch ? updated.count - 1 : updated.firstIndex { $0.fileID == selectedFileID } ?? 0
            select(index)
        }
        startAtLastMatch = false
    }

    private func navigate(_ direction: EditorFindBarView.FindDirection) {
        guard isPresented else {
            startAtLastMatch = direction == .previous
            isPresented = true
            return
        }
        guard lastSearch?.query == query, lastSearch?.caseSensitive == caseSensitive, let selectedIndex else {
            focused = true
            return
        }
        switch direction {
        case .next: select((selectedIndex + 1) % matches.count)
        case .previous: select(selectedIndex == 0 ? matches.count - 1 : selectedIndex - 1)
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        reveal(matches[index])
    }

    private func close() {
        isPresented = false
        focused = false
        matches = []
        selectedIndex = nil
        lastSearch = nil
        startAtLastMatch = false
    }
}
