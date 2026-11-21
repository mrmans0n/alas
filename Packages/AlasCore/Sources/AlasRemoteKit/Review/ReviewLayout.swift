import Foundation

public struct ReviewEntryID: Hashable, Sendable {
    public let namespace: String
    public let path: String

    public init(namespace: String, path: String) {
        self.namespace = namespace
        self.path = path
    }
}

public enum ReviewEntryContent: Equatable, Sendable {
    case notLoaded
    case loading
    case hunks([RemoteDiffHunk], truncated: Bool)
    case note(String)
}

public struct ReviewEntry: Equatable, Sendable {
    public let id: ReviewEntryID
    public let status: String
    public let add: Int
    public let del: Int
    public let renameFrom: String?
    public var content: ReviewEntryContent

    public init(
        id: ReviewEntryID, status: String, add: Int, del: Int, renameFrom: String?,
        content: ReviewEntryContent
    ) {
        self.id = id
        self.status = status
        self.add = add
        self.del = del
        self.renameFrom = renameFrom
        self.content = content
    }
}

public enum ReviewRow: Hashable, Sendable {
    case hunkHeader(entry: ReviewEntryID, hunk: Int)
    case line(entry: ReviewEntryID, hunk: Int, line: Int)
    /// Loading or not yet loaded.
    case placeholder(entry: ReviewEntryID)
    case note(entry: ReviewEntryID, text: String)
    case comment(entry: ReviewEntryID, id: String)
}

public enum ReviewLayout {
    private static let generatedNames: Set<String> = [
        "Package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock",
        "Podfile.lock", "Gemfile.lock", "go.sum", "poetry.lock",
    ]

    public static func rows(
        for entry: ReviewEntry, folded: Bool, comments: [ReviewPlacedComment] = []
    ) -> [ReviewRow] {
        if folded { return [] }
        let id = entry.id
        switch entry.content {
        case .notLoaded, .loading:
            return [.placeholder(entry: id)]
        case let .note(text):
            return [.note(entry: id, text: text)]
        case let .hunks(hunks, truncated):
            if hunks.isEmpty { return [.note(entry: id, text: "No changes to show")] }
            // Comment ids by the base row they follow; `comments` indexes the comment-free rows.
            var after: [Int: [String]] = [:]
            let last = hunks.count + hunks.reduce(0) { $0 + $1.lines.count } - 1
            for c in comments { after[min(c.row ?? 0, last), default: []].append(c.id) }
            var rows: [ReviewRow] = []
            var base = 0
            func add(_ row: ReviewRow) {
                rows.append(row)
                for cid in after[base] ?? [] { rows.append(.comment(entry: id, id: cid)) }
                base += 1
            }
            for (h, hunk) in hunks.enumerated() {
                add(.hunkHeader(entry: id, hunk: h))
                for l in hunk.lines.indices { add(.line(entry: id, hunk: h, line: l)) }
            }
            if truncated { rows.append(.note(entry: id, text: "Diff truncated on the Mac")) }
            return rows
        }
    }

    public static func startsFolded(path: String, add: Int, del: Int) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if generatedNames.contains(name) { return true }
        if name.hasSuffix(".pbxproj"), path.contains(".xcodeproj/") { return true }
        return add + del > 1500
    }
}
