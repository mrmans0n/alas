import Foundation

struct DiffReviewFileID: Codable, Equatable, Hashable, Identifiable, Sendable {
    let namespace: String
    let path: String

    var id: String { rawValue }
    var rawValue: String { "\(namespace):\(path)" }
}

enum DiffReviewInlineFeedbackSide: String, Codable, Equatable, Hashable, Sendable {
    case old
    case new
    case unknown
}

struct DiffReviewInlineFeedbackAnchor: Hashable, Codable, Equatable, Sendable {
    let path: String
    let line: Int?
    let side: DiffReviewInlineFeedbackSide

    var isFileLevel: Bool { line == nil }
}

struct DiffReviewInlineFeedback: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let providerName: String
    let author: String?
    let bodyPreview: String
    let status: ReviewEvidenceStatus
    let providerURL: URL?
    let anchor: DiffReviewInlineFeedbackAnchor
    let evidenceItemID: String
}

enum DiffReviewFileStatus: String, Codable, Equatable, Hashable {
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

    var expandedRailGlyph: String? {
        nil
    }
}

struct DiffReviewFileSummary: Codable, Equatable, Identifiable {
    let id: DiffReviewFileID
    let path: String
    let namespace: String
    let groupID: String?
    let groupTitle: String?
    let status: DiffReviewFileStatus
    let additions: Int
    let deletions: Int
    let isRenderable: Bool
    var originalPath: String? = nil
    var gitStatus: String? = nil

    init(
        path: String,
        namespace: String,
        groupID: String?,
        groupTitle: String?,
        status: DiffReviewFileStatus,
        additions: Int,
        deletions: Int,
        isRenderable: Bool,
        originalPath: String? = nil,
        gitStatus: String? = nil
    ) {
        self.id = DiffReviewFileID(namespace: namespace, path: path)
        self.path = path
        self.namespace = namespace
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isRenderable = isRenderable
        self.originalPath = originalPath
        self.gitStatus = gitStatus
    }

    enum CodingKeys: String, CodingKey {
        case path
        case namespace
        case groupID
        case groupTitle
        case status
        case additions
        case deletions
        case isRenderable
        case originalPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let namespace = try container.decode(String.self, forKey: .namespace)

        self.init(
            path: path,
            namespace: namespace,
            groupID: try container.decodeIfPresent(String.self, forKey: .groupID),
            groupTitle: try container.decodeIfPresent(String.self, forKey: .groupTitle),
            status: try container.decode(DiffReviewFileStatus.self, forKey: .status),
            additions: try container.decode(Int.self, forKey: .additions),
            deletions: try container.decode(Int.self, forKey: .deletions),
            isRenderable: try container.decode(Bool.self, forKey: .isRenderable),
            originalPath: try container.decodeIfPresent(String.self, forKey: .originalPath)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(namespace, forKey: .namespace)
        try container.encodeIfPresent(groupID, forKey: .groupID)
        try container.encodeIfPresent(groupTitle, forKey: .groupTitle)
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

struct DiffReviewStagedMutationActions {
    var unstageFile: (() -> Void)? = nil
    var unstageHunk: ((ParsedDiff.Hunk) -> Void)? = nil
    var isHunkUnstageEnabled: ((ParsedDiff.Hunk) -> Bool)? = nil
    /// The busy-derived component of what `isHunkUnstageEnabled` returns,
    /// captured as plain data. The closure itself can't participate in
    /// render equality, so without this, toggling `busy` wouldn't change
    /// `renderablePresence` and the equality-gated `DiffReviewFileSection`
    /// could leave "Drop from commit" stuck showing a stale enabled state.
    var unstageEnabledBase: Bool = true
}

struct DiffReviewFileSectionModel: Identifiable {
    var id: DiffReviewFileID { summary.id }

    let summary: DiffReviewFileSummary
    let parsedDiff: ParsedDiff?
    let displayModel: DiffDisplayModel?
    let placeholderMessage: String?
    let openFile: (() -> Void)?
    let contextProvider: DiffReviewContextProvider?
    var imageProvider: DiffReviewImageProvider? = nil
    var stagedMutationActions: DiffReviewStagedMutationActions? = nil
}

struct DiffReviewSourceGroup: Equatable, Identifiable {
    let id: String
    let title: String
    let files: [DiffReviewFileSummary]
    let tree: [DiffReviewFileTreeNode]

    init(id: String, title: String, files: [DiffReviewFileSummary]) {
        self.id = id
        self.title = title
        self.files = files
        self.tree = DiffReviewFileTreeBuilder.build(files: files)
    }

    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct DiffReviewSessionModel: Equatable {
    let files: [DiffReviewFileSummary]
    let groups: [DiffReviewSourceGroup]
    let tree: [DiffReviewFileTreeNode]
    let groupsEnabled: Bool

    init(files: [DiffReviewFileSummary], groupsEnabled: Bool) {
        self.groupsEnabled = groupsEnabled
        self.files = groupsEnabled ? files.sorted(by: Self.groupedFileOrder) : files
        self.groups = groupsEnabled ? Self.buildGroups(files: self.files) : []
        self.tree = groupsEnabled ? [] : DiffReviewFileTreeBuilder.build(files: self.files)
    }

    var fileCount: Int { files.count }
    var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    private static func buildGroups(files: [DiffReviewFileSummary]) -> [DiffReviewSourceGroup] {
        let grouped = Dictionary(grouping: files, by: groupKey)
        return grouped.keys
            .sorted(by: groupOrder)
            .map { id in
                let groupFiles = grouped[id] ?? []
                let title = groupFiles.first?.groupTitle ?? id
                return DiffReviewSourceGroup(id: id, title: title, files: groupFiles.sorted(by: groupedFileOrder))
            }
    }

    private static func groupedFileOrder(_ lhs: DiffReviewFileSummary, _ rhs: DiffReviewFileSummary) -> Bool {
        let lhsGroup = groupKey(lhs)
        let rhsGroup = groupKey(rhs)
        if lhsGroup != rhsGroup {
            return groupOrder(lhsGroup, rhsGroup)
        }

        let pathComparison = lhs.path.localizedStandardCompare(rhs.path)
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }

        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func groupKey(_ file: DiffReviewFileSummary) -> String {
        file.groupID ?? file.namespace
    }

    private static func groupOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsOrder = knownGroupOrder(lhs)
        let rhsOrder = knownGroupOrder(rhs)
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        let comparison = lhs.localizedStandardCompare(rhs)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        return lhs < rhs
    }

    private static func knownGroupOrder(_ id: String) -> Int {
        switch id {
        case "unstaged": 0
        case "staged": 1
        default: 2
        }
    }
}

struct DiffReviewLoadedSession {
    let files: [DiffReviewFileSectionModel]
    let summary: DiffReviewSessionModel
}

extension DiffReviewStagedMutationActions {
    /// Closure identity is not comparable; which actions exist plus the
    /// captured `unstageEnabledBase` snapshot is what determines the
    /// rendered buttons and their enabled state.
    var renderableSignature: (Bool, Bool, Bool, Bool) {
        (unstageFile != nil, unstageHunk != nil, isHunkUnstageEnabled != nil, unstageEnabledBase)
    }
}

extension DiffReviewFileSectionModel {
    /// True when this model renders identically to `other`. Ignores closure
    /// identity for `openFile` and mutation action bodies — `stagedMutationActions`
    /// is compared via `renderableSignature` (presence plus the captured
    /// `unstageEnabledBase` snapshot, since that drives whether "Drop from
    /// commit" renders as enabled). `contextProvider` is compared by `id`,
    /// not just presence: `DiffReviewFileSection` keys its own
    /// stale-load-rejection and reset logic off that id (see
    /// `contextStateSignature`), so treating two different providers as
    /// equal would let a swapped-in file keep serving a previous provider's
    /// in-flight/expanded context. `parsedDiff` is intentionally excluded:
    /// `displayModel` is the complete derived payload this view renders and
    /// already carries its precomputed full-content revision.
    func hasSameRenderableContent(as other: DiffReviewFileSectionModel) -> Bool {
        summary == other.summary
            && displayModel == other.displayModel
            && placeholderMessage == other.placeholderMessage
            && (openFile == nil) == (other.openFile == nil)
            && contextProvider?.id == other.contextProvider?.id
            && imageProvider?.id == other.imageProvider?.id
            && (stagedMutationActions?.renderableSignature ?? (false, false, false, true))
                == (other.stagedMutationActions?.renderableSignature ?? (false, false, false, true))
    }
}

extension DiffReviewLoadedSession {
    func hasSameRenderableContent(as other: DiffReviewLoadedSession) -> Bool {
        guard summary == other.summary, files.count == other.files.count else { return false }
        return zip(files, other.files).allSatisfy { $0.hasSameRenderableContent(as: $1) }
    }
}

struct DiffReviewFileTreeNode: Codable, Equatable, Identifiable {
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
    var children: [DiffReviewFileTreeNode]?
    var file: DiffReviewFileSummary?
}

enum DiffReviewFileTreeBuilder {
    static func build(files: [DiffReviewFileSummary]) -> [DiffReviewFileTreeNode] {
        var roots: [String: TreeBuildNode] = [:]

        for file in files {
            let normalizedPath = normalize(file.path)
            guard !normalizedPath.isEmpty else { continue }

            let normalizedFile = DiffReviewFileSummary(
                path: normalizedPath,
                namespace: file.namespace,
                groupID: file.groupID,
                groupTitle: file.groupTitle,
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
        var file: DiffReviewFileSummary?
        var children: [String: TreeBuildNode] = [:]

        init(name: String, path: String, isDirectory: Bool, file: DiffReviewFileSummary?) {
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
        file: DiffReviewFileSummary,
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

    private static func finalise(_ map: [String: TreeBuildNode]) -> [DiffReviewFileTreeNode] {
        map.values.map { node in
            let children = node.isDirectory ? finalise(node.children).sorted(by: nodeOrder) : nil
            return DiffReviewFileTreeNode(
                name: node.name,
                path: node.path,
                kind: node.isDirectory ? .directory : .file,
                children: children,
                file: node.file
            )
        }
    }

    private static func compact(_ nodes: [DiffReviewFileTreeNode]) -> [DiffReviewFileTreeNode] {
        nodes.map { node in
            guard node.kind == .directory else { return node }

            var compacted = DiffReviewFileTreeNode(
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
                compacted = DiffReviewFileTreeNode(
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
        _ lhs: DiffReviewFileTreeNode,
        _ rhs: DiffReviewFileTreeNode
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .directory
        }

        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        if let lhsFile = lhs.file, let rhsFile = rhs.file, lhsFile.id.rawValue != rhsFile.id.rawValue {
            return lhsFile.id.rawValue < rhsFile.id.rawValue
        }

        if lhs.path != rhs.path {
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        return lhs.id < rhs.id
    }
}

struct DiffReviewRailRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case sourceHeader(id: String, title: String, fileCount: Int)
        case directory(String, depth: Int)
        case file(DiffReviewFileSummary, depth: Int, name: String)
        case divider
    }

    let id: String
    let kind: Kind
}

enum DiffReviewRailFilter {
    static func session(
        _ session: DiffReviewSessionModel,
        matching query: String
    ) -> DiffReviewSessionModel {
        let query = normalizedQuery(query)
        guard !query.isEmpty else { return session }

        let files = session.files.filter { file in
            FuzzyMatch.score(query: query, target: file.path) != nil
        }
        return DiffReviewSessionModel(files: files, groupsEnabled: session.groupsEnabled)
    }

    static func isActive(_ query: String) -> Bool {
        !normalizedQuery(query).isEmpty
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DiffReviewRailRows {
    static func rows(for session: DiffReviewSessionModel) -> [DiffReviewRailRow] {
        if !session.groupsEnabled {
            return flattenFiles(session.files)
        }

        return session.groups.enumerated().flatMap { index, group in
            var rows = [
                DiffReviewRailRow(
                    id: "source:\(group.id)",
                    kind: .sourceHeader(id: group.id, title: group.title, fileCount: group.fileCount)
                ),
            ]
            rows.append(contentsOf: flattenFiles(group.files, idScope: group.id))
            if index < session.groups.count - 1 {
                rows.append(DiffReviewRailRow(
                    id: "divider:\(group.id)",
                    kind: .divider
                ))
            }
            return rows
        }
    }

    private static func flattenFiles(
        _ files: [DiffReviewFileSummary],
        idScope: String? = nil
    ) -> [DiffReviewRailRow] {
        var rows: [DiffReviewRailRow] = []
        var emittedDirectories: Set<String> = []

        for file in files {
            if let directory = file.directory, !emittedDirectories.contains(directory) {
                emittedDirectories.insert(directory)
                let id = ["directory", idScope, directory, "0"]
                    .compactMap { $0 }
                    .joined(separator: ":")
                rows.append(DiffReviewRailRow(
                    id: id,
                    kind: .directory(directory, depth: 0)
                ))
            }

            let id = ["file", idScope, file.id.rawValue]
                .compactMap { $0 }
                .joined(separator: ":")
            rows.append(DiffReviewRailRow(
                id: id,
                kind: .file(file, depth: file.directory == nil ? 0 : 1, name: file.basename)
            ))
        }

        return rows
    }
}
