import SwiftUI
import AppKit

/// A session the composer can attach as context (see `ACPSessionReference`).
struct ACPSessionMentionCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let projectId: String
    let title: String
    let agentName: String
    let worktreeName: String
}

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
    let worktreeRoot: URL
    var sessionsProvider: (@MainActor () async -> [ACPSessionMentionCandidate])? = nil
    let onPick: (URL) -> Void
    var onPickSession: (ACPSessionMentionCandidate) -> Void = { _ in }
    var symbolMentions: ACPSymbolMentionSource? = nil
    var onPickSymbol: (SymbolEntry, Bool) -> Void = { _, _ in }
    let onCancel: () -> Void
    let filesProvider: (@Sendable () async -> [URL])?
    let panelLink: MentionPickerPanelLink

    /// The picker's size; `ACPMentionPanel` opens at it.
    static let panelSize = CGSize(width: 560, height: 440)

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var highlight: Int = 0
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
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
            symbolTask?.cancel()
            symbolTask = nil
            rankTask?.cancel()
            rankTask = nil
        }
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
        HStack(spacing: 7) {
            Image(systemName: "at")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($searchFocused)
                .onChange(of: query) { _, _ in
                    scrollOnHighlightChange = false
                    highlight = 0
                    rescheduleRank(preserveHighlight: false)
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private var scopeBar: some View {
        let scopes = offeredScopes
        if !scopes.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(scopes.enumerated()), id: \.element) { index, item in
                    let number = index + 1
                    Button { select(item) } label: {
                        Text(item.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
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
            .padding(.horizontal, 10).padding(.bottom, 6)
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
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if ranked.isEmpty {
                        Text(isIndexing ? "Indexing worktree…" : "No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                            .padding(.horizontal, 10).padding(.vertical, 10)
                    } else {
                        ForEach(Array(ranked.enumerated()), id: \.element) { idx, item in
                            // Data-based id (the item), not the row position:
                            // a positional id freezes LazyVStack rows against
                            // the ranked list changing as you type.
                            VStack(alignment: .leading, spacing: 1) {
                                if let header = groupHeader(at: idx) {
                                    Text(header)
                                        .font(.system(size: 10, weight: .medium))
                                        .tracking(0.6)
                                        .foregroundStyle(theme.color("fg-faint"))
                                        .padding(.horizontal, 10).padding(.top, idx == 0 ? 2 : 8)
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
                .padding(.vertical, 4)
            }
            .onChange(of: highlight) { _, new in
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
        let isOn = idx == highlight
        return Button { onPickSymbol(symbol, false) } label: {
            HStack(spacing: 8) {
                Text(symbol.kind.badgeLetter)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: symbol.kind.badgeLabelColor))
                    .frame(width: 16, height: 16)
                    .background(Color(nsColor: symbol.kind.badgeBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                (Text(symbol.container.map { $0 + "." } ?? "").foregroundStyle(theme.color("fg-faint"))
                    + Text(symbol.kind.isCallable ? symbol.name + "()" : symbol.name).fontWeight(.semibold))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if MentionSymbolRanking.isTestPath(symbol.relativePath) {
                    Text("test")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
                Spacer(minLength: 8)
                Text(symbol.relativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight = idx
            }
        }
    }

    private func row(idx: Int, session: ACPSessionMentionCandidate) -> some View {
        let isOn = idx == highlight
        return Button { onPickSession(session) } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 14)
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                Text("\(session.agentName) · \(session.worktreeName)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight = idx
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, file: URL) -> some View {
        let isOn = idx == highlight
        let name = file.lastPathComponent
        let rel = isAbsoluteQuery ? name : file.path.replacingOccurrences(of: worktreeRoot.path + "/", with: "")
        let parent = isAbsoluteQuery ? "" : (rel as NSString).deletingLastPathComponent

        Button { onPick(file) } label: {
            HStack(spacing: 8) {
                Image(systemName: file.hasDirectoryPath ? "folder" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                if !parent.isEmpty {
                    Text(parent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                scrollOnHighlightChange = false
                highlight = idx
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
            if isAbsoluteQuery, ranked.indices.contains(highlight),
               case .file(let file) = ranked[highlight], file.hasDirectoryPath {
                query = MentionAbsolutePath.query(entering: file)
            } else {
                select(scope.cycled(by: 1, in: offeredScopes))
            }
        case .previousScope:
            select(scope.cycled(by: -1, in: offeredScopes))
        case .insert(let includeCode):
            guard ranked.indices.contains(highlight) else { return }
            switch ranked[highlight] {
            case .session(let session): onPickSession(session)
            case .symbol(let symbol): onPickSymbol(symbol, includeCode)
            case .file(let file): onPick(file)
            }
        }
    }

    private func select(_ next: MentionScope) {
        guard next != scope else { return }
        scope = next
        highlight = 0
        rescheduleRank(preserveHighlight: false)
    }

    private func moveHighlight(by offset: Int) {
        let next = MentionPickerNavigation.move(from: highlight, by: offset, count: ranked.count)
        guard next != highlight else { return }
        scrollOnHighlightChange = true
        highlight = next
    }

    /// Sessions load on their own, so they show up while files still index.
    private func populateSessions() {
        guard let sessionsProvider else { return }
        Task { @MainActor in
            sessions = await sessionsProvider()
            rescheduleRank(preserveHighlight: true)
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
            rescheduleRank(preserveHighlight: true)
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
                rescheduleRank(preserveHighlight: true)
            }
            symbolIndexing = nil
        }
    }

    private func rescheduleRank(preserveHighlight: Bool) {
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
                // Read the live highlight here, not before the await: the
                // user may have moved it while ranking or a drill-down read ran.
                let current = ranked.indices.contains(highlight) ? ranked[highlight] : nil
                let currentIndex = highlight
                ranked = items
                if preserveHighlight {
                    highlight = MentionPickerNavigation.index(preserving: current, fallback: currentIndex, in: items)
                }
            }
        }
    }
}

/// Sessions shown above the files: the most recent ones for an empty query,
/// otherwise the best fuzzy matches on title, agent, and worktree.
enum MentionSessionRanking {
    static let maxDisplay = 5

    /// `candidates` arrive most recent first; ties keep that order.
    static func rank(
        _ candidates: [ACPSessionMentionCandidate], query: String, limit: Int = maxDisplay
    ) -> [ACPSessionMentionCandidate] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Array(candidates.prefix(limit)) }
        var scored: [(candidate: ACPSessionMentionCandidate, score: Double, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            let detail = "\(candidate.agentName) \(candidate.worktreeName)"
            var total = 0.0
            var matched = true
            for token in tokens {
                // Title matches outrank agent or worktree matches.
                let titleScore = FuzzyMatch.score(query: token, target: candidate.title)?.score.advanced(by: 8)
                let detailScore = FuzzyMatch.score(query: token, target: detail)?.score
                guard let best = [titleScore, detailScore].compactMap(\.self).max() else {
                    matched = false
                    break
                }
                total += best
            }
            if matched { scored.append((candidate, total, order)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.candidate)
    }
}

enum MentionPickerNavigation {
    static func move(from index: Int, by offset: Int, count: Int) -> Int {
        min(max(0, count - 1), max(0, index + offset))
    }

    /// After results change under an unchanged query, keep the user's
    /// highlighted item if it is still listed; otherwise keep the position.
    static func index(preserving item: MentionPickerItem?, fallback: Int, in items: [MentionPickerItem]) -> Int {
        if let item, let index = items.firstIndex(of: item) { return index }
        return move(from: fallback, by: 0, count: items.count)
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

// MARK: - Fuzzy matching

enum MentionFuzzy {
    static func deduplicated(files: [URL], relativeTo root: URL) -> [URL] {
        var result: [URL] = []
        var indices: [String: Int] = [:]
        for file in files {
            let path = relativePath(for: file, root: root)
            if let index = indices[path] {
                if file.hasDirectoryPath { result[index] = file }
            } else {
                indices[path] = result.count
                result.append(file)
            }
        }
        return result
    }

    static func collectFiles(under root: URL, limit: Int) -> [URL] {
        var out: [URL] = []
        let skipDirs: Set<String> = [
            ".git", "node_modules", ".build", "build", "DerivedData", ".alas",
            ".next", "dist", "out", "target", ".venv", "venv", ".tox", ".cache",
            "__pycache__", ".idea", ".vscode", ".superpowers",
        ]
        guard let it = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: []
        ) else { return [] }

        for case let url as URL in it {
            if out.count >= limit { break }
            let name = url.lastPathComponent
            if skipDirs.contains(name) {
                it.skipDescendants()
                continue
            }
            if name.hasPrefix(".") {
                it.skipDescendants()
                continue
            }
            // Directories are pickable too — the enumerator yields them with
            // `hasDirectoryPath` set, which the picker uses to show a folder
            // icon and to emit a directory resource link. We still recurse into
            // them (no `skipDescendants`) so their files remain available.
            out.append(url)
        }
        out.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        return out
    }

    /// Derive every directory implied by a set of worktree-relative paths, as
    /// directory-flagged URLs under `root`. `git ls-files` only emits files
    /// (collapsing untracked directories to a trailing-slash entry), so tracked
    /// directories never appear on their own — we reconstruct the full set from
    /// each path's ancestors. A trailing slash marks the whole path as a
    /// directory; otherwise the last component is a file and is dropped.
    static func ancestorDirectories(forRelativePaths paths: [String], root: URL) -> [URL] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let isDirEntry = path.hasSuffix("/")
            let comps = path.split(separator: "/").map(String.init)
            let dirCount = isDirEntry ? comps.count : comps.count - 1
            guard dirCount > 0 else { continue }
            for end in 1...dirCount {
                let dir = comps[0..<end].joined(separator: "/")
                if seen.insert(dir).inserted { ordered.append(dir) }
            }
        }
        return ordered.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Directory URLs to add to the picker for a `git ls-files`-style listing.
    /// The caller resolves each entry's on-disk directory-ness: untracked
    /// directories arrive collapsed with git's trailing slash, but submodule
    /// gitlinks arrive like a file path (no slash). Normalizing directory
    /// entries to a trailing slash lets `ancestorDirectories` emit the entry
    /// itself — not just its parent — so submodule folders stay pickable.
    static func pickerDirectories(forEntries entries: [(path: String, isDirectory: Bool)], root: URL) -> [URL] {
        let normalized = entries.map { entry -> String in
            entry.isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
        }
        return ancestorDirectories(forRelativePaths: normalized, root: root)
    }

    static func rank(files: [URL], query: String, limit: Int, relativeTo root: URL) -> [URL] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return Array(files.prefix(limit)) }

        let normalizedQuery = query.lowercased()
        var scored: [(url: URL, pathPriority: Int, score: Double, relativePath: String)] = []
        for f in files {
            let relativePath = relativePath(for: f, root: root)
            guard let score = score(file: f, relativePath: relativePath, tokens: tokens) else {
                continue
            }
            let normalizedPath = relativePath.lowercased()
            let pathPriority = normalizedPath == normalizedQuery ? 3
                : normalizedPath.hasPrefix(normalizedQuery) ? 2
                : normalizedPath.contains(normalizedQuery) ? 1
                : 0
            scored.append((f, pathPriority, score, relativePath))
        }
        scored.sort {
            if $0.pathPriority != $1.pathPriority { return $0.pathPriority > $1.pathPriority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.url))
    }

    private static func score(file: URL, relativePath: String, tokens: [String]) -> Double? {
        var total = 0.0
        for token in tokens {
            let nameScore = FuzzyMatch.score(query: token, target: file.lastPathComponent)?
                .score
                .advanced(by: 8)
            let pathScore = FuzzyMatch.score(query: token, target: relativePath)?.score
            guard let best = [nameScore, pathScore].compactMap(\.self).max() else {
                return nil
            }
            total += best
        }
        return total - Double(relativePath.count) * 0.001
    }

    private static func relativePath(for file: URL, root: URL) -> String {
        let commonRoot = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = commonRoot.hasSuffix("/") ? commonRoot : commonRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
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
