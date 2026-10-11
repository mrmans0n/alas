import Foundation
import Observation

public struct GGSplitCommitTarget: Equatable, Sendable {
    public let worktreeId: String
    public let targetGGID: String?
    public let targetSHA: String

    public var commandTarget: String { targetGGID ?? targetSHA }

    public init(worktreeId: String, targetGGID: String?, targetSHA: String) {
        self.worktreeId = worktreeId
        self.targetGGID = targetGGID
        self.targetSHA = targetSHA
    }
}

public struct GGSplitLoadedDescription: Equatable, Sendable {
    public let description: GGSplitDescription
    public let stackIdentity: GGStackIdentity

    public init(description: GGSplitDescription, stackIdentity: GGStackIdentity) {
        self.description = description
        self.stackIdentity = stackIdentity
    }
}

@MainActor
public protocol GGSplitCommitServicing: AnyObject {
    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription
    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws
}

public enum GGSplitCommitFileGroupKind: Equatable, Sendable {
    case selectable
    case remainderOnly

    public var idToken: String {
        switch self {
        case .selectable: "selectable"
        case .remainderOnly: "remainder"
        }
    }
}

public enum GGSplitCommitDestination: Equatable, Sendable {
    case newCommit
    case originalCommit
}

public struct GGSplitCommitFileGroup: Equatable, Identifiable, Sendable {
    // A path can appear as both a selectable group and a remainder-only group
    // (e.g. text edits plus a metadata/chmod change on the same file), so the
    // kind is part of the identity to keep ForEach IDs unique.
    public var id: String { "\(kind.idToken):\(path)" }
    public let path: String
    public let hunks: [GGSplitHunk]
    public let kind: GGSplitCommitFileGroupKind

    public init(path: String, hunks: [GGSplitHunk], kind: GGSplitCommitFileGroupKind) {
        self.path = path
        self.hunks = hunks
        self.kind = kind
    }
}

public struct GGSplitPreviewFile: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let hunkIDs: [String]
    public let diff: ParsedDiff

    public init(path: String, hunkIDs: [String], diff: ParsedDiff) {
        self.path = path
        self.hunkIDs = hunkIDs
        self.diff = diff
    }
}

public struct GGSplitPreview: Equatable, Sendable {
    public let files: [GGSplitPreviewFile]
    public let nonTextualFiles: [String]

    public static let empty = GGSplitPreview(files: [], nonTextualFiles: [])

    public init(files: [GGSplitPreviewFile], nonTextualFiles: [String]) {
        self.files = files
        self.nonTextualFiles = nonTextualFiles
    }
}

public struct GGSplitCommitDraft: Equatable, Sendable {
    public var selectedHunkIDs: Set<String>
    public var firstMessage: String
    public var remainderMessage: String

    public init(selectedHunkIDs: Set<String>, firstMessage: String, remainderMessage: String) {
        self.selectedHunkIDs = selectedHunkIDs
        self.firstMessage = firstMessage
        self.remainderMessage = remainderMessage
    }
}

public enum GGSplitCommitValidationError: Error, Equatable, Sendable {
    case unavailable
    case notLoaded
    case emptySelection
    case allHunksSelected
    case emptyFirstMessage
    case emptyRemainderMessage
}

extension GGSplitCommitValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Update GG to use native Split Commit"
        case .notLoaded: "Load the split plan before applying it."
        case .emptySelection: "Select at least one hunk for the new commit."
        case .allHunksSelected: "Leave at least one hunk for the original commit."
        case .emptyFirstMessage: "Enter a message for the new commit."
        case .emptyRemainderMessage: "Enter a message for the original commit."
        }
    }
}

public struct GGSplitPrivatePlanFile: Sendable {
    public let url: URL
    public let directoryURL: URL

    public func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    public init(url: URL, directoryURL: URL) {
        self.url = url
        self.directoryURL = directoryURL
    }
}

public struct GGSplitPrivatePlanWriter {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    public init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    public func write(_ plan: GGSplitPlan) throws -> GGSplitPrivatePlanFile {
        let directoryURL = temporaryDirectory
            .appendingPathComponent("alas-gg-split-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(plan)
            let stagingURL = directoryURL.appendingPathComponent("plan.json.tmp")
            guard fileManager.createFile(
                atPath: stagingURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)

            let planURL = directoryURL.appendingPathComponent("plan.json")
            try fileManager.moveItem(at: stagingURL, to: planURL)
            return GGSplitPrivatePlanFile(url: planURL, directoryURL: directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }
}

@Observable
@MainActor
public final class GGSplitCommitModel {
    public nonisolated static let unavailableReason = "Update GG to use native Split Commit"
    public nonisolated static let workflowUnavailableReason = "Native Split Commit is unavailable."

    private let service: any GGSplitCommitServicing
    private let target: GGSplitCommitTarget
    private let capabilities: GGCapabilities
    private let workflowAvailable: Bool
    private let planWriter: GGSplitPrivatePlanWriter
    private let initialDraft: GGSplitCommitDraft?
    private var stackIdentity: GGStackIdentity?

    public private(set) var description: GGSplitDescription!
    public private(set) var fileGroups: [GGSplitCommitFileGroup] = []
    public var selectedHunkIDs: Set<String> = []
    public var firstMessage = ""
    public var remainderMessage = ""

    public init(
        service: any GGSplitCommitServicing,
        target: GGSplitCommitTarget,
        capabilities: GGCapabilities,
        workflowAvailable: Bool,
        initialDraft: GGSplitCommitDraft? = nil,
        planWriter: GGSplitPrivatePlanWriter = GGSplitPrivatePlanWriter()
    ) {
        self.service = service
        self.target = target
        self.capabilities = capabilities
        self.workflowAvailable = workflowAvailable
        self.initialDraft = initialDraft
        self.planWriter = planWriter
    }

    public var isAvailable: Bool { capabilities.structuredSplit && workflowAvailable }
    public var unavailableReason: String? {
        if !capabilities.structuredSplit { return Self.unavailableReason }
        if !workflowAvailable { return Self.workflowUnavailableReason }
        return nil
    }
    public var targetSHA: String? { description?.target.sha }
    public var targetTree: String? { description?.target.tree }
    public var targetGGID: String? { description?.target.ggID }
    public var planToken: String? { description?.planToken }
    public var draft: GGSplitCommitDraft {
        GGSplitCommitDraft(
            selectedHunkIDs: selectedHunkIDs,
            firstMessage: firstMessage,
            remainderMessage: remainderMessage
        )
    }

    public var validationMessage: String? {
        do {
            _ = try validatedPlan()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var canApply: Bool { validationMessage == nil }

    public var firstPreview: GGSplitPreview {
        preview(selecting: { selectedHunkIDs.contains($0.id) }, includesNonTextual: false)
    }

    public var remainderPreview: GGSplitPreview {
        preview(selecting: { !selectedHunkIDs.contains($0.id) }, includesNonTextual: true)
    }

    public func load() async throws {
        guard isAvailable else { throw GGSplitCommitValidationError.unavailable }
        let draftToRestore = description == nil ? initialDraft : draft
        let loaded = try await service.loadDescription(target: target)
        description = loaded.description
        stackIdentity = loaded.stackIdentity
        let knownHunkIDs = Set(loaded.description.hunks.map(\.id))
        selectedHunkIDs = draftToRestore?.selectedHunkIDs.intersection(knownHunkIDs) ?? []
        firstMessage = draftToRestore?.firstMessage ?? loaded.description.firstMessage
        remainderMessage = draftToRestore?.remainderMessage ?? loaded.description.remainderMessage
        fileGroups = Self.makeFileGroups(from: loaded.description)
    }

    public func toggleHunk(_ id: String) {
        guard let destination = destination(for: id) else { return }
        assignHunk(id, to: destination == .newCommit ? .originalCommit : .newCommit)
    }

    public func destination(for id: String) -> GGSplitCommitDestination? {
        guard description?.hunks.contains(where: { $0.id == id }) == true else { return nil }
        return selectedHunkIDs.contains(id) ? .newCommit : .originalCommit
    }

    public func assignHunk(_ id: String, to destination: GGSplitCommitDestination) {
        guard self.destination(for: id) != nil else { return }
        switch destination {
        case .newCommit: selectedHunkIDs.insert(id)
        case .originalCommit: selectedHunkIDs.remove(id)
        }
    }

    public func assignHunks(in group: GGSplitCommitFileGroup, to destination: GGSplitCommitDestination) {
        for hunk in group.hunks {
            assignHunk(hunk.id, to: destination)
        }
    }

    public func validatedPlan() throws -> GGSplitPlan {
        guard isAvailable else { throw GGSplitCommitValidationError.unavailable }
        guard let description else { throw GGSplitCommitValidationError.notLoaded }
        guard !selectedHunkIDs.isEmpty else { throw GGSplitCommitValidationError.emptySelection }
        let hasRemainderContent = selectedHunkIDs.count < description.hunks.count
            || !description.nonTextualFiles.isEmpty
        guard hasRemainderContent else {
            throw GGSplitCommitValidationError.allHunksSelected
        }
        let knownIDs = Set(description.hunks.map(\.id))
        guard selectedHunkIDs.isSubset(of: knownIDs) else {
            throw GGSplitCommitValidationError.emptySelection
        }
        let first = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { throw GGSplitCommitValidationError.emptyFirstMessage }
        let remainder = remainderMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { throw GGSplitCommitValidationError.emptyRemainderMessage }

        return GGSplitPlan(
            version: 1,
            planToken: description.planToken,
            target: description.target,
            selectedHunkIDs: description.hunks.map(\.id).filter(selectedHunkIDs.contains),
            firstMessage: first,
            remainderMessage: remainder
        )
    }

    public func apply() async throws {
        let plan = try validatedPlan()
        guard let stackIdentity else { throw GGSplitCommitValidationError.notLoaded }
        let privateFile = try planWriter.write(plan)
        defer { privateFile.remove() }
        try await service.applySplit(
            planURL: privateFile.url,
            target: plan.target,
            planToken: plan.planToken,
            confirmedAgainst: stackIdentity
        )
    }

    private static func makeFileGroups(from description: GGSplitDescription) -> [GGSplitCommitFileGroup] {
        var paths: [String] = []
        var hunksByPath: [String: [GGSplitHunk]] = [:]
        for hunk in description.hunks {
            if hunksByPath[hunk.path] == nil { paths.append(hunk.path) }
            hunksByPath[hunk.path, default: []].append(hunk)
        }
        var groups = paths.map {
            GGSplitCommitFileGroup(path: $0, hunks: hunksByPath[$0] ?? [], kind: .selectable)
        }
        groups.append(contentsOf: description.nonTextualFiles.map {
            GGSplitCommitFileGroup(path: $0, hunks: [], kind: .remainderOnly)
        })
        return groups
    }

    private func preview(
        selecting predicate: (GGSplitHunk) -> Bool,
        includesNonTextual: Bool
    ) -> GGSplitPreview {
        guard let description else { return .empty }
        let grouped = Self.makeFileGroups(from: description)
        let files = grouped.compactMap { group -> GGSplitPreviewFile? in
            let hunks = group.hunks.filter(predicate)
            guard !hunks.isEmpty else { return nil }
            let rawDiff = hunks.map { hunk in
                hunk.patch.hasPrefix("@@") ? hunk.patch : "\(hunk.header)\n\(hunk.patch)"
            }.joined(separator: "\n")
            return GGSplitPreviewFile(
                path: group.path,
                hunkIDs: hunks.map(\.id),
                diff: DiffParser.parse(rawDiff)
            )
        }
        return GGSplitPreview(
            files: files,
            nonTextualFiles: includesNonTextual ? description.nonTextualFiles : []
        )
    }
}
