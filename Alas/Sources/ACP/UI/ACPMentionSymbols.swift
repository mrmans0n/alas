import Foundation

/// Symbols the `@` picker offers for one worktree.
struct ACPSymbolMentionSource {
    /// Project-wide index; nil for remote worktrees.
    let index: (@MainActor () async -> AsyncStream<WorktreeSymbolIndex.Snapshot>)?
    /// For `File.swift#name`: the symbols of the worktree file that best
    /// matches `fileQuery`. Works local and remote.
    let fileSymbols: @Sendable (_ fileQuery: String) async -> [SymbolEntry]

    /// The symbols of the worktree file that best matches `fileQuery`.
    static func symbols(ofFileMatching fileQuery: String, root: URL, fileIndex: FileIndex) async -> [SymbolEntry] {
        // From FileIndex paths, not the picker's file list: that list
        // drops remote entries, and drill-down is remote's only route.
        // Each step can be slow (enumeration, a remote read, parsing),
        // and a newer keystroke or the closed picker cancels this one.
        let entries = (try? await fileIndex.entries(forWorktreePath: root)) ?? []
        guard !Task.isCancelled else { return [] }
        let urls = entries.map { root.appendingPathComponent($0.relativePath) }
        guard let best = MentionFuzzy.rank(files: urls, query: fileQuery, limit: 1, relativeTo: root).first,
              !Task.isCancelled
        else { return [] }
        let relativePath = String(best.path.dropFirst(root.path.count + 1))
        guard let source = await SymbolSource.read(root: root, relativePath: relativePath),
              !Task.isCancelled
        else { return [] }
        return SymbolExtractor.symbols(in: source, relativePath: relativePath)
    }
}

enum MentionScope: Int, CaseIterable, Identifiable {
    case all, files, symbols, sessions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .files: "Files"
        case .symbols: "Symbols"
        case .sessions: "Sessions"
        }
    }

    /// Scopes the picker offers, in chip order; ⌘1… follow that order. With
    /// neither symbols nor sessions, All and Files would list the same rows,
    /// so there are no scopes.
    static func offered(symbols: Bool, sessions: Bool) -> [MentionScope] {
        guard symbols || sessions else { return [] }
        return allCases.filter { ($0 != .symbols || symbols) && ($0 != .sessions || sessions) }
    }

    /// The scope ⇥ (`offset` 1) or ⇧⇥ (-1) selects: the next offered one,
    /// wrapping around. Stays put when no scopes are offered.
    func cycled(by offset: Int, in offered: [MentionScope]) -> MentionScope {
        guard let index = offered.firstIndex(of: self) else { return offered.first ?? self }
        let count = offered.count
        return offered[((index + offset) % count + count) % count]
    }
}

enum MentionSymbolQuery: Equatable {
    case project(String)
    /// `File.swift#name`: symbols of the best-matching file only.
    case file(file: String, symbol: String)

    static func parse(_ query: String) -> MentionSymbolQuery {
        guard let hash = query.lastIndex(of: "#") else { return .project(query) }
        let file = query[..<hash].trimmingCharacters(in: .whitespaces)
        guard !file.isEmpty else { return .project(query) }
        return .file(file: file, symbol: String(query[query.index(after: hash)...]).trimmingCharacters(in: .whitespaces))
    }
}

/// What the picker ranks for one query. The view runs the plan.
struct MentionQueryPlan: Equatable {
    enum Symbols: Equatable {
        case none
        case project(query: String, limit: Int)
        /// `File.swift#name`: the symbols of the best-matching file.
        case file(file: String, symbol: String)
    }

    var sessions: Bool
    var symbols: Symbols
    /// Filter for the file list; nil lists no files.
    var fileQuery: String?

    /// `query` is trimmed. `displayLimit` caps the Symbols scope.
    static func make(
        query: String, scope: MentionScope, isAbsolute: Bool, offersSymbols: Bool, displayLimit: Int
    ) -> MentionQueryPlan {
        let wantsFiles = scope == .all || scope == .files
        let wantsSessions = scope == .all || scope == .sessions
        let wantsSymbols = offersSymbols && (scope == .all || scope == .symbols)
        if isAbsolute {
            return MentionQueryPlan(sessions: false, symbols: .none, fileQuery: wantsFiles ? query : nil)
        }
        switch offersSymbols ? MentionSymbolQuery.parse(query) : .project(query) {
        case .file(let file, let symbol):
            // A drill-down lists that file's symbols alone, so ⏎ can't
            // attach the whole file or a session instead.
            if wantsSymbols {
                return MentionQueryPlan(sessions: false, symbols: .file(file: file, symbol: symbol), fileQuery: nil)
            }
            return MentionQueryPlan(sessions: wantsSessions, symbols: .none, fileQuery: wantsFiles ? file : nil)
        case .project(let text):
            let symbols: Symbols = wantsSymbols && (!text.isEmpty || scope == .symbols)
                ? .project(query: text, limit: scope == .symbols ? displayLimit : MentionSymbolRanking.allScopeLimit)
                : .none
            return MentionQueryPlan(sessions: wantsSessions, symbols: symbols, fileQuery: wantsFiles ? query : nil)
        }
    }
}

/// The picker footer's symbol indexing state.
enum MentionSymbolIndexing: Equatable {
    /// Index requested, no snapshot yet: the file count isn't known.
    case starting
    case progress(indexed: Int, total: Int)
}

enum MentionSymbolRanking {
    /// Symbols shown in the All scope; the Symbols scope shows up to the
    /// picker's full limit.
    static let allScopeLimit = 8

    private static let testDirectories: Set<String> = ["Tests", "test", "tests", "__tests__", "spec"]
    private static let testSuffixes = ["Test", "Tests", "Spec", "_test", ".test"]

    static func isTestPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.dropLast().contains(where: testDirectories.contains) { return true }
        guard let file = components.last else { return false }
        let stem = (file as NSString).deletingPathExtension
        return testSuffixes.contains { stem.hasSuffix($0) }
    }

    static func rank(_ symbols: [SymbolEntry], query: String, limit: Int) -> [SymbolEntry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Array(symbols.prefix(limit)) }
        let normalized = query.lowercased()
        struct Scored {
            let entry: SymbolEntry
            let namePriority: Int
            let score: Double
            let isTest: Bool
            let order: Int
        }
        var scored: [Scored] = []
        for (order, entry) in symbols.enumerated() {
            var total = 0.0
            var matched = true
            for token in tokens {
                let nameScore = FuzzyMatch.score(query: token, target: entry.name)?.score.advanced(by: 8)
                let qualifiedScore = FuzzyMatch.score(query: token, target: entry.qualifiedName)?.score
                guard let best = [nameScore, qualifiedScore].compactMap(\.self).max() else {
                    matched = false
                    break
                }
                total += best
            }
            guard matched else { continue }
            let name = entry.name.lowercased()
            let priority = name == normalized ? 3 : name.hasPrefix(normalized) ? 2 : name.contains(normalized) ? 1 : 0
            scored.append(Scored(entry: entry, namePriority: priority, score: total,
                                 isTest: isTestPath(entry.relativePath), order: order))
        }
        scored.sort {
            if $0.namePriority != $1.namePriority { return $0.namePriority > $1.namePriority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.kind.isType != $1.entry.kind.isType { return $0.entry.kind.isType }
            if $0.isTest != $1.isTest { return !$0.isTest }
            if $0.entry.relativePath.count != $1.entry.relativePath.count {
                return $0.entry.relativePath.count < $1.entry.relativePath.count
            }
            return $0.order < $1.order
        }
        return scored.prefix(limit).map(\.entry)
    }
}
