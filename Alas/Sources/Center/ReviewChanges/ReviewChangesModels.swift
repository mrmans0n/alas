import Foundation

struct ReviewChangesFileID: Codable, Equatable, Hashable, Identifiable {
    let source: ReviewChangesSource
    let path: String

    var id: String { rawValue }
    var rawValue: String { "\(source.rawValue):\(path)" }
}

enum ReviewChangesSource: String, Codable, Equatable, Hashable, Comparable {
    case unstaged
    case staged

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        }
    }

    static func < (lhs: ReviewChangesSource, rhs: ReviewChangesSource) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .unstaged: 0
        case .staged: 1
        }
    }
}

enum ReviewChangesFileStatus: String, Codable, Equatable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case conflicted
    case unknown

    init(gitStatus: String, conflict: ConflictKind? = nil) {
        if conflict != nil {
            self = .conflicted
            return
        }

        switch gitStatus.prefix(1).uppercased() {
        case "A":
            self = .added
        case "M", "T":
            self = .modified
        case "D":
            self = .deleted
        case "R":
            self = .renamed
        case "C":
            self = .copied
        case "U":
            self = .conflicted
        default:
            self = .unknown
        }
    }

    var glyph: String {
        switch self {
        case .added: "+"
        case .modified: "~"
        case .deleted: "-"
        case .renamed: ">"
        case .copied: "="
        case .conflicted: "!"
        case .unknown: "?"
        }
    }
}

struct ReviewChangesFileSummary: Codable, Equatable, Identifiable {
    let id: ReviewChangesFileID
    let path: String
    let source: ReviewChangesSource
    let status: ReviewChangesFileStatus
    let additions: Int
    let deletions: Int
    let isRenderable: Bool
    var originalPath: String? = nil

    init(
        path: String,
        source: ReviewChangesSource,
        status: ReviewChangesFileStatus,
        additions: Int,
        deletions: Int,
        isRenderable: Bool,
        originalPath: String? = nil
    ) {
        self.id = ReviewChangesFileID(source: source, path: path)
        self.path = path
        self.source = source
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isRenderable = isRenderable
        self.originalPath = originalPath
    }

    enum CodingKeys: String, CodingKey {
        case path
        case source
        case status
        case additions
        case deletions
        case isRenderable
        case originalPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let source = try container.decode(ReviewChangesSource.self, forKey: .source)

        self.init(
            path: path,
            source: source,
            status: try container.decode(ReviewChangesFileStatus.self, forKey: .status),
            additions: try container.decode(Int.self, forKey: .additions),
            deletions: try container.decode(Int.self, forKey: .deletions),
            isRenderable: try container.decode(Bool.self, forKey: .isRenderable),
            originalPath: try container.decodeIfPresent(String.self, forKey: .originalPath)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(source, forKey: .source)
        try container.encode(status, forKey: .status)
        try container.encode(additions, forKey: .additions)
        try container.encode(deletions, forKey: .deletions)
        try container.encode(isRenderable, forKey: .isRenderable)
        try container.encodeIfPresent(originalPath, forKey: .originalPath)
    }

    var basename: String {
        (path as NSString).lastPathComponent
    }

    var directory: String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty || directory == "." ? nil : directory
    }
}

struct ReviewChangesFileSectionModel: Equatable, Identifiable {
    var id: ReviewChangesFileID { summary.id }

    let summary: ReviewChangesFileSummary
    let parsedDiff: ParsedDiff?
    let displayModel: DiffDisplayModel?
    let placeholderMessage: String?
}

struct ReviewChangesSourceSection: Equatable, Identifiable {
    var id: ReviewChangesSource { source }

    let source: ReviewChangesSource
    let files: [ReviewChangesFileSummary]
    let tree: [ReviewChangesFileTreeNode]

    init(source: ReviewChangesSource, files: [ReviewChangesFileSummary]) {
        self.source = source
        self.files = files
        self.tree = ReviewChangesFileTreeBuilder.build(files: files)
    }

    var title: String { source.title }
    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct ReviewChangesSessionModel: Equatable {
    let files: [ReviewChangesFileSummary]
    let sections: [ReviewChangesSourceSection]

    init(files: [ReviewChangesFileSummary]) {
        self.files = files.sorted(by: Self.fileOrder)
        self.sections = Dictionary(grouping: self.files, by: \.source)
            .map { source, files in
                ReviewChangesSourceSection(source: source, files: files.sorted(by: Self.fileOrder))
            }
            .sorted { $0.source < $1.source }
    }

    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    private static func fileOrder(_ lhs: ReviewChangesFileSummary, _ rhs: ReviewChangesFileSummary) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

struct ReviewChangesLoadedSession: Equatable {
    let files: [ReviewChangesFileSectionModel]
    let summary: ReviewChangesSessionModel
}

struct ReviewChangesFileTreeNode: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case directory
        case file
    }

    var id: String {
        if let file {
            return "\(kind.rawValue):\(file.id.rawValue)"
        }
        return "\(kind.rawValue):\(path)"
    }

    let name: String
    let path: String
    let kind: Kind
    var children: [ReviewChangesFileTreeNode]?
    var file: ReviewChangesFileSummary?
}

enum ReviewChangesFileTreeBuilder {
    static func build(files: [ReviewChangesFileSummary]) -> [ReviewChangesFileTreeNode] {
        var roots: [String: TreeBuildNode] = [:]

        for file in files {
            let normalizedPath = normalize(file.path)
            guard !normalizedPath.isEmpty else { continue }

            let normalizedFile = ReviewChangesFileSummary(
                path: normalizedPath,
                source: file.source,
                status: file.status,
                additions: file.additions,
                deletions: file.deletions,
                isRenderable: file.isRenderable,
                originalPath: file.originalPath
            )
            let parts = normalizedPath.split(separator: "/").map(String.init)
            insert(parts: parts, into: &roots, file: normalizedFile, prefix: "")
        }

        return compact(finalise(roots)).sorted(by: nodeOrder)
    }

    private final class TreeBuildNode {
        let name: String
        let path: String
        let isDirectory: Bool
        var file: ReviewChangesFileSummary?
        var children: [String: TreeBuildNode] = [:]

        init(name: String, path: String, isDirectory: Bool, file: ReviewChangesFileSummary?) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.file = file
        }
    }

    private static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        return parts.joined(separator: "/")
    }

    private static func insert(
        parts: [String],
        into map: inout [String: TreeBuildNode],
        file: ReviewChangesFileSummary,
        prefix: String
    ) {
        guard let head = parts.first else { return }

        let isLeaf = parts.count == 1
        let nodePath = prefix.isEmpty ? head : "\(prefix)/\(head)"

        if isLeaf {
            let key = file.id.rawValue
            if map[key] == nil {
                map[key] = TreeBuildNode(name: head, path: file.path, isDirectory: false, file: file)
            }
        } else {
            let key = nodeKey(name: head, isDirectory: true)
            let directory = map[key] ?? TreeBuildNode(name: head, path: nodePath, isDirectory: true, file: nil)
            map[key] = directory
            insert(parts: Array(parts.dropFirst()), into: &directory.children, file: file, prefix: nodePath)
        }
    }

    private static func nodeKey(name: String, isDirectory: Bool) -> String {
        "\(isDirectory ? "directory" : "file"):\(name)"
    }

    private static func finalise(_ map: [String: TreeBuildNode]) -> [ReviewChangesFileTreeNode] {
        map.values.map { node in
            let children = node.isDirectory ? finalise(node.children).sorted(by: nodeOrder) : nil
            return ReviewChangesFileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.isDirectory ? .directory : .file,
                children: children,
                file: node.file
            )
        }
    }

    private static func compact(_ nodes: [ReviewChangesFileTreeNode]) -> [ReviewChangesFileTreeNode] {
        nodes.map { node in
            guard node.kind == .directory else { return node }

            var compacted = ReviewChangesFileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.kind,
                children: compact(node.children ?? []),
                file: nil
            )

            while
                let children = compacted.children,
                children.count == 1,
                let child = children.first,
                child.kind == .directory
            {
                compacted = ReviewChangesFileTreeNode(
                    name: "\(compacted.name)/\(child.name)",
                    path: child.path,
                    kind: .directory,
                    children: child.children,
                    file: nil
                )
            }

            return compacted
        }
    }

    private static func nodeOrder(
        _ lhs: ReviewChangesFileTreeNode,
        _ rhs: ReviewChangesFileTreeNode
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .directory
        }

        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        if let lhsFile = lhs.file, let rhsFile = rhs.file {
            if lhsFile.source != rhsFile.source {
                return lhsFile.source < rhsFile.source
            }
            if lhsFile.id.rawValue != rhsFile.id.rawValue {
                return lhsFile.id.rawValue < rhsFile.id.rawValue
            }
        }

        if lhs.path != rhs.path {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        return lhs.id < rhs.id
    }
}
