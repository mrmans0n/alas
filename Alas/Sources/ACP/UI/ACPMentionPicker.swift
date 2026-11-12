import SwiftUI
import AppKit

/// Sessions the `@` picker offers, and the lookup a session dropped from
/// the sidebar goes through. Both leave out the composer's own session and
/// sessions of other projects.
struct ACPSessionMentionSource {
    /// Async: it can read stores of worktrees not opened in this run.
    let candidates: @MainActor () async -> [ACPSessionMentionCandidate]
    let candidate: @MainActor (_ sessionId: String) async -> ACPSessionMentionCandidate?
}

enum MentionPickerItem: Hashable {
    case session(ACPSessionMentionCandidate)
    case symbol(SymbolEntry)
    case file(URL)
}

/// SwiftUI fuzzy file and session picker for the composer's @-mention
/// popover. Hosted inside an NSPanel (see `ACPMentionPickerPanel`) so it can
/// float above the chat with proper key forwarding.
struct ACPMentionPickerView: View {
    @Environment(\.designScale) private var scale
    let worktreeRoot: URL
    var sessionsProvider: (@MainActor () async -> [ACPSessionMentionCandidate])? = nil
    let onPick: (URL) -> Void
    var onPickSession: (ACPSessionMentionCandidate) -> Void = { _ in }
    var symbolMentions: ACPSymbolMentionSource? = nil
    var onPickSymbol: (SymbolEntry, Bool) -> Void = { _, _ in }
    let onCancel: () -> Void
    let filesProvider: (@Sendable () async -> [URL])?
    let panelLink: MentionPickerPanelLink
    /// Shows the highlighted symbol's code beside the picker; nil shows none.
    var symbolPreview: MentionSymbolPreviewModel? = nil

    /// The picker's size; `ACPMentionPanel` opens at it.
    static let panelSize = CGSize(width: 560, height: 440)
    /// The picker's own coordinates, top-left at the panel's top-left.
    static let coordinateSpace = "mentionPicker"

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var highlight = MentionPickerHighlight()
    @FocusState private var searchFocused: Bool
    @State private var allFiles: [URL] = []
    @State private var sessions: [ACPSessionMentionCandidate] = []
    @State private var ranked: [MentionPickerItem] = []
    @State private var isIndexing: Bool = true
    @State private var rankTask: Task<Void, Never>?
    @State private var rankGeneration: Int = 0
    @State private var scrollOnHighlightChange = false
    @State private var scope: MentionScope = .all
    @State private var allSymbols: [SymbolEntry] = []
    @State private var symbolIndexing: MentionSymbolIndexing? = nil
    @State private var symbolTask: Task<Void, Never>?
    @State private var isClosed = false
    /// The highlighted row, when it is a symbol row on screen.
    @State private var highlightedSymbolRow: CGRect?
    @State private var listViewport: CGRect = .zero

    private let maxDisplay = 80

    private var isAbsoluteQuery: Bool {
        !worktreeRoot.isRemoteAlasPath
            && MentionAbsolutePath.isAbsolute(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 0) {
            search
            scopeBar
            Divider().background(theme.color("line"))
            list
                .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        .coordinateSpace(.named(Self.coordinateSpace))
        .onChange(of: symbolPreviewRequest, initial: true) { _, request in
            symbolPreview?.update(request)
        }
        .defaultFocus($searchFocused, true)
        .onAppear {
            panelLink.attach(keys: { handleKey($0) }, focus: { searchFocused = true })
            populateSessions()
            populateFiles()
            populateSymbols()
        }
        .onDisappear {
            isClosed = true
            panelLink.detach()
            symbolPreview?.update(nil)
            symbolTask?.cancel()
            symbolTask = nil
            rankTask?.cancel()
            rankTask = nil
        }
    }

    /// The highlighted symbol and where its row sits, while the row's middle
    /// is inside the list's visible area.
    private var symbolPreviewRequest: MentionSymbolPreviewRequest? {
        guard symbolPreview != nil, ranked.indices.contains(highlight.index),
              case .symbol(let symbol) = ranked[highlight.index],
              let row = highlightedSymbolRow,
              row.midY >= listViewport.minY, row.midY <= listViewport.maxY else { return nil }
        return MentionSymbolPreviewRequest(symbol: symbol, rowMidY: row.midY)
    }

    private var offeredScopes: [MentionScope] {
        MentionScope.offered(symbols: symbolMentions != nil, sessions: sessionsProvider != nil)
    }

    private var placeholder: String {
        let subject = switch (symbolMentions != nil, sessionsProvider != nil) {
        case (true, true): "files, symbols & sessions"
        case (true, false): "files, symbols & folders"
        case (false, true): "files, folders & sessions"
        case (false, false): "files & folders"
        }
        return "Search \(subject)… (/ or ~/ to browse)"
    }

    private var search: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "at")
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(scale.meta.font(design: .monospaced))
                .focused($searchFocused)
                .onChange(of: query) { _, _ in
                    scrollOnHighlightChange = false
                    highlight.reset()
                    rescheduleRank()
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
    }

    @ViewBuilder
    private var scopeBar: some View {
        let scopes = offeredScopes
        if !scopes.isEmpty {
            HStack(spacing: scale.space[1]) {
                ForEach(Array(scopes.enumerated()), id: \.element) { index, item in
                    let number = index + 1
                    Button { select(item) } label: {
                        Text(item.title)
                            .font(scale.captionFont)
                            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[0])
                            .background(scope == item ? theme.color("accent").opacity(0.22) : theme.color("bg-2"))
                            .foregroundStyle(scope == item ? theme.color("accent") : theme.color("fg-faint"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .help("\(item.title) (⌘\(number))")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[2]).padding(.bottom, scale.space[2])
        }
    }

    @ViewBuilder
    private var footer: some View {
        let text: String? = switch symbolIndexing {
        case .starting:
            "Indexing symbols…"
        case .progress(let indexed, let total):
            "Indexing symbols… \(indexed) of \(total) files"
        case nil where symbolMentions == nil:
            nil
        case nil where symbolMentions?.index == nil && scope == .symbols:
            "Project symbols aren't indexed on remote worktrees. Type File.swift#name."
        case nil:
            offeredScopes.isEmpty
                ? "⏎ insert · ⌥⏎ insert with code · File.swift#name"
                : "⏎ insert · ⌥⏎ insert with code · ⇥ next scope · File.swift#name"
        }
        if let text {
            Divider().background(theme.color("line"))
            Text(text)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.space[0]) {
                    if ranked.isEmpty {
                        Text(isIndexing ? "Indexing worktree…" : "No matches")
                            .font(scale.metaFont)
                            .foregroundStyle(theme.color("fg-faint"))
                            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
                    } else {
                        ForEach(Array(ranked.enumerated()), id: \.element) { idx, item in
                            // Data-based id (the item), not the row position:
                            // a positional id freezes LazyVStack rows against
                            // the ranked list changing as you type.
                            VStack(alignment: .leading, spacing: scale.space[0]) {
                                if let header = groupHeader(at: idx) {
                                    Text(header)
                                        .font(scale.captionFont)
                                        .tracking(0.6)
                                        .foregroundStyle(theme.color("fg-faint"))
                                        .padding(.horizontal, scale.space[2]).padding(.top, idx == 0 ? 2 : 8)
                                }
                                switch item {
                                case .file(let file): row(idx: idx, file: file)
                                case .session(let session): row(idx: idx, session: session)
                                case .symbol(let symbol): row(idx: idx, symbol: symbol)
                                }
                            }
                            .id(item)
                        }
                    }
                }
                .padding(.vertical, scale.space[1])
            }
            .onPreferenceChange(HighlightedSymbolRowKey.self) { highlightedSymbolRow = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: {
                listViewport = $0
            }
            .onChange(of: highlight.index) { _, new in
                guard scrollOnHighlightChange else { return }
                scrollOnHighlightChange = false
                guard ranked.indices.contains(new) else { return }
                proxy.scrollTo(ranked[new], anchor: .center)
            }
        }
    }

    private func groupHeader(at index: Int) -> String? {
        func group(_ item: MentionPickerItem) -> String {
            switch item {
            case .session: "SESSIONS"
            case .symbol: "SYMBOLS"
            case .file: "FILES"
            }
        }
        let current = group(ranked[index])
        if index > 0, group(ranked[index - 1]) == current { return nil }
        let groups = Set(ranked.map(group))
        return groups.count > 1 ? current : nil
    }

    private func row(idx: Int, symbol: SymbolEntry) -> some View {
        let isOn = idx == highlight.index
        return Button { onPickSymbol(symbol, false) } label: {
            HStack(spacing: scale.space[2]) {
                Text(symbol.kind.badgeLetter)
                    .font(scale.caption.font(weight: .bold))
                    .foregroundStyle(Color(nsColor: symbol.kind.badgeLabelColor))
                    .frame(width: 16, height: 16)
                    .background(Color(nsColor: symbol.kind.badgeBackground))
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                (Text(symbol.container.map { $0 + "." } ?? "").foregroundStyle(theme.color("fg-faint"))
                    + Text(symbol.kind.isCallable ? symbol.name + "()" : symbol.name).fontWeight(.semibold))
                    .font(scale.meta.font(design: .monospaced))
                    .lineLimit(1)
                if MentionSymbolRanking.isTestPath(symbol.relativePath) {
                    Text("test")
                        .font(scale.caption.font(weight: .regular))
                        .foregroundStyle(theme.color("fg-faint"))
                        .padding(.horizontal, scale.space[1])
                        .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Text(symbol.relativePath)
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The start line tells overloads apart, so it never truncates.
                    Text(":\(symbol.lineRange.lowerBound + 1)")
                        .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-dim"))
                        .fixedSize()
                }
                .font(scale.meta.font(design: .monospaced))
            }
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .background {
                if isOn, symbolPreview != nil {
                    GeometryReader { proxy in
                        Color.clear.preference(key: HighlightedSymbolRowKey.self,
                                               value: proxy.frame(in: .named(Self.coordinateSpace)))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight.choose(idx)
            }
        }
    }

    private func row(idx: Int, session: ACPSessionMentionCandidate) -> some View {
        let isOn = idx == highlight.index
        return Button { onPickSession(session) } label: {
            HStack(spacing: scale.space[2]) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 14)
                Text(session.title)
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                Text("\(session.agentName) · \(session.worktreeName)")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight.choose(idx)
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, file: URL) -> some View {
        let isOn = idx == highlight.index
        let name = file.lastPathComponent
        let rel = isAbsoluteQuery ? name : file.path.replacingOccurrences(of: worktreeRoot.path + "/", with: "")
        let parent = isAbsoluteQuery ? "" : (rel as NSString).deletingLastPathComponent

        Button { onPick(file) } label: {
            HStack(spacing: scale.space[2]) {
                Image(systemName: file.hasDirectoryPath ? "folder" : "doc.text")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 14)
                Text(name)
                    .font(scale.meta.font(weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                if !parent.isEmpty {
                    Text(parent)
                        .font(scale.meta.font(design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight.choose(idx)
            }
        }
    }

    private func handleKey(_ key: MentionPickerKey) {
        switch key {
        case .cancel:
            onCancel()
        case .up:
            moveHighlight(by: -1)
        case .down:
            moveHighlight(by: 1)
        case .nextScope:
            // Absolute-path browsing keeps ⇥ for entering the highlighted folder.
            if isAbsoluteQuery, ranked.indices.contains(highlight.index),
               case .file(let file) = ranked[highlight.index], file.hasDirectoryPath {
                query = MentionAbsolutePath.query(entering: file)
            } else {
                select(scope.cycled(by: 1, in: offeredScopes))
            }
        case .previousScope:
            select(scope.cycled(by: -1, in: offeredScopes))
        case .insert(let includeCode):
            guard ranked.indices.contains(highlight.index) else { return }
            switch ranked[highlight.index] {
            case .session(let session): onPickSession(session)
            case .symbol(let symbol): onPickSymbol(symbol, includeCode)
            case .file(let file): onPick(file)
            }
        }
    }

    private func select(_ next: MentionScope) {
        guard next != scope else { return }
        scope = next
        highlight.reset()
        rescheduleRank()
    }

    private func moveHighlight(by offset: Int) {
        let next = MentionPickerNavigation.move(from: highlight.index, by: offset, count: ranked.count)
        guard next != highlight.index else { return }
        scrollOnHighlightChange = true
        highlight.choose(next)
    }

    /// Sessions load on their own, so they show up while files still index.
    private func populateSessions() {
        guard let sessionsProvider else { return }
        Task { @MainActor in
            sessions = await sessionsProvider()
            rescheduleRank()
        }
    }

    private func populateFiles() {
        Task { @MainActor in
            isIndexing = true
            let files: [URL]
            if let provider = filesProvider {
                files = await provider()
            } else {
                let root = worktreeRoot
                files = await Task.detached(priority: .userInitiated) {
                    MentionFuzzy.collectFiles(under: root, limit: 5000)
                }.value
            }
            allFiles = MentionFuzzy.deduplicated(files: files, relativeTo: worktreeRoot)
            isIndexing = false
            rescheduleRank()
        }
    }

    private func populateSymbols() {
        guard let index = symbolMentions?.index else { return }
        symbolIndexing = .starting
        symbolTask = Task { @MainActor in
            for await snapshot in await index() {
                allSymbols = snapshot.symbols
                symbolIndexing = snapshot.isComplete
                    ? nil
                    : .progress(indexed: snapshot.indexedFiles, total: snapshot.totalFiles)
                rescheduleRank()
            }
            symbolIndexing = nil
        }
    }

    private func rescheduleRank() {
        rankTask?.cancel()
        rankTask = nil
        // Sessions and files load in untracked tasks that can finish after
        // the panel closed.
        guard !isClosed else { return }
        rankGeneration &+= 1
        let gen = rankGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = allFiles
        let symbols = allSymbols
        let root = worktreeRoot
        let isAbsolute = !root.isRemoteAlasPath && MentionAbsolutePath.isAbsolute(query: q)
        let plan = MentionQueryPlan.make(
            query: q, scope: scope, isAbsolute: isAbsolute,
            offersSymbols: symbolMentions != nil, displayLimit: maxDisplay)
        let sessionItems = plan.sessions
            ? MentionSessionRanking.rank(sessions, query: q).map(MentionPickerItem.session)
            : []
        let fileSymbols = symbolMentions?.fileSymbols
        rankTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
            var symbolItems: [SymbolEntry] = []
            switch plan.symbols {
            case .none:
                break
            case .project(let text, let limit):
                symbolItems = MentionSymbolRanking.rank(symbols, query: text, limit: limit)
            case .file(let fileQuery, let symbolQuery):
                if let fileSymbols {
                    let candidates = await fileSymbols(fileQuery)
                    if Task.isCancelled { return }
                    symbolItems = MentionSymbolRanking.rank(candidates, query: symbolQuery, limit: maxDisplay)
                }
            }
            var fileItems: [URL] = []
            if let fileQuery = plan.fileQuery {
                if fileQuery.isEmpty {
                    fileItems = Array(files.prefix(maxDisplay))
                } else {
                    fileItems = isAbsolute
                        ? MentionAbsolutePath.entries(forQuery: fileQuery, limit: maxDisplay)
                        : MentionFuzzy.rank(files: files, query: fileQuery, limit: maxDisplay, relativeTo: root)
                }
            }
            if Task.isCancelled { return }
            let items = sessionItems + symbolItems.map(MentionPickerItem.symbol) + fileItems.map(MentionPickerItem.file)
            await MainActor.run {
                guard rankGeneration == gen else { return }
                // Rebase on the live highlight here, not before the await:
                // the user may have moved it while ranking or a drill-down read ran.
                let previous = ranked
                ranked = items
                highlight.rebase(from: previous, to: items)
            }
        }
    }
}

enum MentionPickerNavigation {
    static func move(from index: Int, by offset: Int, count: Int) -> Int {
        min(max(0, count - 1), max(0, index + offset))
    }
}

/// The picker's highlighted row. Until the user moves it, it stays on the
/// top result while results reorder (symbol indexing streams in better
/// matches). Once moved, it follows the chosen item while that is listed,
/// otherwise it keeps the position.
struct MentionPickerHighlight: Equatable {
    private(set) var index = 0
    private var isChosen = false

    /// The query or scope changed: back to the top result.
    mutating func reset() {
        index = 0
        isChosen = false
    }

    mutating func choose(_ index: Int) {
        self.index = index
        isChosen = true
    }

    mutating func rebase(from old: [MentionPickerItem], to new: [MentionPickerItem]) {
        guard isChosen else { index = 0; return }
        if old.indices.contains(index), let moved = new.firstIndex(of: old[index]) {
            index = moved
        } else {
            index = MentionPickerNavigation.move(from: index, by: 0, count: new.count)
        }
    }
}

/// Keys `ACPMentionPanel` hands the picker before the search field's
/// editor sees them: the editor would take ⇥ to move focus, ⏎ to submit,
/// and ↑/↓ to move its caret.
enum MentionPickerKey: Equatable {
    case up, down, cancel, nextScope, previousScope
    case insert(includeCode: Bool)

    /// nil leaves the key to the search field.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let modifiers = modifiers.intersection([.shift, .control, .option, .command])
        switch keyCode {
        case 126 where modifiers.isEmpty: self = .up
        case 125 where modifiers.isEmpty: self = .down
        case 53 where modifiers.isEmpty: self = .cancel
        case 48 where modifiers.isEmpty: self = .nextScope
        case 48 where modifiers == .shift: self = .previousScope
        case 36, 76:
            guard modifiers.isEmpty || modifiers == .option else { return nil }
            self = .insert(includeCode: modifiers == .option)
        default: return nil
        }
    }
}

/// What `ACPMentionPanel` forwards to the picker view it hosts.
@MainActor
final class MentionPickerPanelLink {
    private var keyHandler: ((MentionPickerKey) -> Void)?
    private var focusHandler: (() -> Void)?
    private var focusPending = false

    /// Called from the view's `onAppear`. SwiftUI drops a focus change made
    /// there once the picker has other buttons, such as the scope tabs, so a
    /// pending focus request runs on the next main-queue turn.
    func attach(keys: @escaping (MentionPickerKey) -> Void, focus: @escaping () -> Void) {
        keyHandler = keys
        focusHandler = focus
        if focusPending {
            focusPending = false
            DispatchQueue.main.async { [weak self] in self?.focusHandler?() }
        }
    }

    func detach() {
        keyHandler = nil
        focusHandler = nil
    }

    /// False until the view attaches, leaving the key to AppKit.
    func handle(_ key: MentionPickerKey) -> Bool {
        guard let keyHandler else { return false }
        keyHandler(key)
        return true
    }

    /// The panel became key: focus the search field now, or once the view
    /// attaches if it has not appeared yet.
    func focusSearch() {
        if let focusHandler {
            focusHandler()
        } else {
            focusPending = true
        }
    }
}

// MARK: - Absolute path browsing

/// A query starting with `/` or `~/` leaves the worktree index and browses
/// the filesystem one directory at a time: everything before the last `/` is
/// the directory, the rest filters its entries.
enum MentionAbsolutePath {
    static func isAbsolute(query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~/") || query == "~"
    }

    /// `query` with `~` expanded, split into the directory to list and the
    /// name fragment being typed.
    static func split(_ query: String) -> (directory: String, filter: String) {
        let expanded: String
        if query == "~" {
            expanded = NSHomeDirectory() + "/"
        } else if query.hasPrefix("~/") {
            expanded = NSHomeDirectory() + query.dropFirst()
        } else {
            expanded = query
        }
        guard let slash = expanded.lastIndex(of: "/") else { return ("/", expanded) }
        let directory = String(expanded[..<slash])
        return (directory.isEmpty ? "/" : directory, String(expanded[expanded.index(after: slash)...]))
    }

    /// Entries of the directory named by `query`, folders first, filtered by
    /// the fragment after the last `/` (prefix matches before substring
    /// matches). Dotfiles only show once the fragment starts with `.`.
    static func entries(forQuery query: String, limit: Int) -> [URL] {
        let (directory, filter) = split(query)
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let options: FileManager.DirectoryEnumerationOptions = filter.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: keys, options: options
        ) else { return [] }
        let needle = filter.lowercased()
        var prefixMatches: [(url: URL, isDirectory: Bool)] = []
        var substringMatches: [(url: URL, isDirectory: Bool)] = []
        for url in urls {
            let name = url.lastPathComponent
            let lowered = name.lowercased()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let entry = (URL(fileURLWithPath: url.path, isDirectory: isDirectory), isDirectory)
            if needle.isEmpty || lowered.hasPrefix(needle) {
                prefixMatches.append(entry)
            } else if lowered.contains(needle) {
                substringMatches.append(entry)
            }
        }
        func ordered(_ entries: [(url: URL, isDirectory: Bool)]) -> [URL] {
            entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }.map(\.url)
        }
        return Array((ordered(prefixMatches) + ordered(substringMatches)).prefix(limit))
    }

    /// Query that descends into `directory`.
    static func query(entering directory: URL) -> String {
        directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    }
}
