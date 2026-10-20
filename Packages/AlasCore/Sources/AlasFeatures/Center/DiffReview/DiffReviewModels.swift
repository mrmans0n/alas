import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum DiffReviewInlineFeedbackSide: String, Codable, Equatable, Hashable, Sendable {
    case old
    case new
    case unknown
}

public struct DiffReviewInlineFeedbackAnchor: Hashable, Codable, Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let side: DiffReviewInlineFeedbackSide

    public var isFileLevel: Bool { line == nil }

    public init(path: String, line: Int?, side: DiffReviewInlineFeedbackSide) {
        self.path = path
        self.line = line
        self.side = side
    }
}

public struct DiffReviewInlineFeedback: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let providerName: String
    public let author: String?
    public let bodyPreview: String
    public let status: ReviewEvidenceStatus
    public let providerURL: URL?
    public let anchor: DiffReviewInlineFeedbackAnchor
    public let evidenceItemID: String

    public init(id: String, providerName: String, author: String?, bodyPreview: String, status: ReviewEvidenceStatus, providerURL: URL?, anchor: DiffReviewInlineFeedbackAnchor, evidenceItemID: String) {
        self.id = id
        self.providerName = providerName
        self.author = author
        self.bodyPreview = bodyPreview
        self.status = status
        self.providerURL = providerURL
        self.anchor = anchor
        self.evidenceItemID = evidenceItemID
    }
}

public enum DiffReviewFileStatus: String, Codable, Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case conflicted
    case unknown

    public init(gitStatus: String, conflict: ConflictKind? = nil) {
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

    public var glyph: String {
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

    public var expandedRailGlyph: String? {
        nil
    }
}

public struct DiffReviewFileSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: DiffReviewFileID
    public let path: String
    public let namespace: String
    public let groupID: String?
    public let groupTitle: String?
    public let status: DiffReviewFileStatus
    public let additions: Int
    public let deletions: Int
    public let isRenderable: Bool
    public var originalPath: String? = nil
    public var gitStatus: String? = nil

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

    public var basename: String {
        (path as NSString).lastPathComponent
    }

    public var directory: String? {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty || directory == "." ? nil : directory
    }
}

public struct DiffReviewStagedMutationActions {
    public var unstageFile: (() -> Void)? = nil
    public var unstageHunk: ((ParsedDiff.Hunk) -> Void)? = nil
    public var isHunkUnstageEnabled: ((ParsedDiff.Hunk) -> Bool)? = nil
    /// The busy-derived component of what `isHunkUnstageEnabled` returns,
    /// captured as plain data. The closure itself can't participate in
    /// render equality, so without this, toggling `busy` wouldn't change
    /// `renderablePresence` and the equality-gated `DiffReviewFileSection`
    /// could leave "Drop from commit" stuck showing a stale enabled state.
    public var unstageEnabledBase: Bool = true

    public init(unstageFile: (() -> Void)? = nil, unstageHunk: ((ParsedDiff.Hunk) -> Void)? = nil, isHunkUnstageEnabled: ((ParsedDiff.Hunk) -> Bool)? = nil, unstageEnabledBase: Bool = true) {
        self.unstageFile = unstageFile
        self.unstageHunk = unstageHunk
        self.isHunkUnstageEnabled = isHunkUnstageEnabled
        self.unstageEnabledBase = unstageEnabledBase
    }
}

public struct DiffReviewFileSectionModel: Identifiable {
    public var id: DiffReviewFileID { summary.id }

    public let summary: DiffReviewFileSummary
    public let parsedDiff: ParsedDiff?
    public let displayModel: DiffDisplayModel?
    public let placeholderMessage: String?
    public let openFile: (() -> Void)?
    public let contextProvider: DiffReviewContextProvider?
    public var imageProvider: DiffReviewImageProvider? = nil
    public var stagedMutationActions: DiffReviewStagedMutationActions? = nil
    /// True while the file is listed but its diff is still loading.
    public var isPending: Bool = false

    public init(summary: DiffReviewFileSummary, parsedDiff: ParsedDiff?, displayModel: DiffDisplayModel?, placeholderMessage: String?, openFile: (() -> Void)?, contextProvider: DiffReviewContextProvider?, imageProvider: DiffReviewImageProvider? = nil, stagedMutationActions: DiffReviewStagedMutationActions? = nil, isPending: Bool = false) {
        self.summary = summary
        self.parsedDiff = parsedDiff
        self.displayModel = displayModel
        self.placeholderMessage = placeholderMessage
        self.openFile = openFile
        self.contextProvider = contextProvider
        self.imageProvider = imageProvider
        self.stagedMutationActions = stagedMutationActions
        self.isPending = isPending
    }

    /// A listed file whose diff has not loaded yet.
    public static func pending(summary: DiffReviewFileSummary) -> DiffReviewFileSectionModel {
        DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            isPending: true
        )
    }
}

public struct DiffReviewSourceGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let files: [DiffReviewFileSummary]
    public let tree: [DiffReviewFileTreeNode]

    public init(id: String, title: String, files: [DiffReviewFileSummary]) {
        self.id = id
        self.title = title
        self.files = files
        self.tree = DiffReviewFileTreeBuilder.build(files: files)
    }

    public var fileCount: Int { files.count }
    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct DiffReviewSessionModel: Equatable, Sendable {
    public let files: [DiffReviewFileSummary]
    public let groups: [DiffReviewSourceGroup]
    public let tree: [DiffReviewFileTreeNode]
    public let groupsEnabled: Bool

    public init(files: [DiffReviewFileSummary], groupsEnabled: Bool) {
        self.groupsEnabled = groupsEnabled
        self.files = groupsEnabled ? files.sorted(by: Self.groupedFileOrder) : files
        self.groups = groupsEnabled ? Self.buildGroups(files: self.files) : []
        self.tree = groupsEnabled ? [] : DiffReviewFileTreeBuilder.build(files: self.files)
    }

    public var fileCount: Int { files.count }
    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

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

public struct DiffReviewLoadedSession {
    public let files: [DiffReviewFileSectionModel]
    public let summary: DiffReviewSessionModel

    public init(files: [DiffReviewFileSectionModel], summary: DiffReviewSessionModel) {
        self.files = files
        self.summary = summary
    }
}

extension DiffReviewStagedMutationActions {
    /// Closure identity is not comparable; which actions exist plus the
    /// captured `unstageEnabledBase` snapshot is what determines the
    /// rendered buttons and their enabled state.
    public var renderableSignature: (Bool, Bool, Bool, Bool) {
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
    public func hasSameRenderableContent(as other: DiffReviewFileSectionModel) -> Bool {
        summary == other.summary
            && displayModel == other.displayModel
            && placeholderMessage == other.placeholderMessage
            && isPending == other.isPending
            && (openFile == nil) == (other.openFile == nil)
            && contextProvider?.id == other.contextProvider?.id
            && imageProvider?.id == other.imageProvider?.id
            && (stagedMutationActions?.renderableSignature ?? (false, false, false, true))
                == (other.stagedMutationActions?.renderableSignature ?? (false, false, false, true))
    }
}

extension DiffReviewLoadedSession {
    public func hasSameRenderableContent(as other: DiffReviewLoadedSession) -> Bool {
        guard summary == other.summary, files.count == other.files.count else { return false }
        return zip(files, other.files).allSatisfy { $0.hasSameRenderableContent(as: $1) }
    }
}

public struct DiffReviewFileTreeNode: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
    }

    public var id: String {
        if let file {
            return "\(kind.rawValue):\(file.id.rawValue)"
        }
        return "\(kind.rawValue):\(path)"
    }

    public let name: String
    public let path: String
    public let kind: Kind
    public var children: [DiffReviewFileTreeNode]?
    public var file: DiffReviewFileSummary?

    public init(name: String, path: String, kind: Kind, children: [DiffReviewFileTreeNode]? = nil, file: DiffReviewFileSummary? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
        self.file = file
    }
}

public enum DiffReviewFileTreeBuilder: Sendable {
    public static func build(files: [DiffReviewFileSummary]) -> [DiffReviewFileTreeNode] {
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

public struct DiffReviewRailRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sourceHeader(id: String, title: String, fileCount: Int)
        case directory(String, depth: Int)
        case file(DiffReviewFileSummary, depth: Int, name: String)
        case divider
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum DiffReviewRailFilter: Sendable {
    public static func session(
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

    public static func isActive(_ query: String) -> Bool {
        !normalizedQuery(query).isEmpty
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DiffReviewRailRows: Sendable {
    public static func rows(for session: DiffReviewSessionModel) -> [DiffReviewRailRow] {
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
