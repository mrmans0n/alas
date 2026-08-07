import Foundation
import Observation

struct GGSplitCommitTarget: Equatable, Sendable {
    let worktreeId: String
    let targetGGID: String?
    let targetSHA: String

    var commandTarget: String { targetGGID ?? targetSHA }
}

struct GGSplitLoadedDescription: Equatable, Sendable {
    let description: GGSplitDescription
    let stackIdentity: GGStackIdentity
}

@MainActor
protocol GGSplitCommitServicing: AnyObject {
    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription
    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws
}

enum GGSplitCommitFileGroupKind: Equatable {
    case selectable
    case remainderOnly

    var idToken: String {
        switch self {
        case .selectable: "selectable"
        case .remainderOnly: "remainder"
        }
    }
}

enum GGSplitCommitDestination: Equatable {
    case newCommit
    case originalCommit
}

struct GGSplitCommitFileGroup: Equatable, Identifiable {
    // A path can appear as both a selectable group and a remainder-only group
    // (e.g. text edits plus a metadata/chmod change on the same file), so the
    // kind is part of the identity to keep ForEach IDs unique.
    var id: String { "\(kind.idToken):\(path)" }
    let path: String
    let hunks: [GGSplitHunk]
    let kind: GGSplitCommitFileGroupKind
}

struct GGSplitPreviewFile: Equatable, Identifiable {
    var id: String { path }
    let path: String
    let hunkIDs: [String]
    let diff: ParsedDiff
}

struct GGSplitPreview: Equatable {
    let files: [GGSplitPreviewFile]
    let nonTextualFiles: [String]

    static let empty = GGSplitPreview(files: [], nonTextualFiles: [])
}

struct GGSplitCommitDraft: Equatable {
    var selectedHunkIDs: Set<String>
    var firstMessage: String
    var remainderMessage: String
}

enum GGSplitCommitValidationError: Error, Equatable {
    case unavailable
    case notLoaded
    case emptySelection
    case allHunksSelected
    case emptyFirstMessage
    case emptyRemainderMessage
}

extension GGSplitCommitValidationError: LocalizedError {
    var errorDescription: String? {
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

struct GGSplitPrivatePlanFile {
    let url: URL
    let directoryURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct GGSplitPrivatePlanWriter {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func write(_ plan: GGSplitPlan) throws -> GGSplitPrivatePlanFile {
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
final class GGSplitCommitModel {
    static let unavailableReason = "Update GG to use native Split Commit"
    static let workflowUnavailableReason = "Native Split Commit is unavailable."

    private let service: any GGSplitCommitServicing
    private let target: GGSplitCommitTarget
    private let capabilities: GGCapabilities
    private let workflowAvailable: Bool
    private let planWriter: GGSplitPrivatePlanWriter
    private let initialDraft: GGSplitCommitDraft?
    private var stackIdentity: GGStackIdentity?

    private(set) var description: GGSplitDescription!
    private(set) var fileGroups: [GGSplitCommitFileGroup] = []
    var selectedHunkIDs: Set<String> = []
    var firstMessage = ""
    var remainderMessage = ""

    init(
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

    var isAvailable: Bool { capabilities.structuredSplit && workflowAvailable }
    var unavailableReason: String? {
        if !capabilities.structuredSplit { return Self.unavailableReason }
        if !workflowAvailable { return Self.workflowUnavailableReason }
        return nil
    }
    var targetSHA: String? { description?.target.sha }
    var targetTree: String? { description?.target.tree }
    var targetGGID: String? { description?.target.ggID }
    var planToken: String? { description?.planToken }
    var draft: GGSplitCommitDraft {
        GGSplitCommitDraft(
            selectedHunkIDs: selectedHunkIDs,
            firstMessage: firstMessage,
            remainderMessage: remainderMessage
        )
    }

    var validationMessage: String? {
        do {
            _ = try validatedPlan()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canApply: Bool { validationMessage == nil }

    var firstPreview: GGSplitPreview {
        preview(selecting: { selectedHunkIDs.contains($0.id) }, includesNonTextual: false)
    }

    var remainderPreview: GGSplitPreview {
        preview(selecting: { !selectedHunkIDs.contains($0.id) }, includesNonTextual: true)
    }

    func load() async throws {
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

    func toggleHunk(_ id: String) {
        guard let destination = destination(for: id) else { return }
        assignHunk(id, to: destination == .newCommit ? .originalCommit : .newCommit)
    }

    func destination(for id: String) -> GGSplitCommitDestination? {
        guard description?.hunks.contains(where: { $0.id == id }) == true else { return nil }
        return selectedHunkIDs.contains(id) ? .newCommit : .originalCommit
    }

    func assignHunk(_ id: String, to destination: GGSplitCommitDestination) {
        guard self.destination(for: id) != nil else { return }
        switch destination {
        case .newCommit: selectedHunkIDs.insert(id)
        case .originalCommit: selectedHunkIDs.remove(id)
        }
    }

    func assignHunks(in group: GGSplitCommitFileGroup, to destination: GGSplitCommitDestination) {
        for hunk in group.hunks {
            assignHunk(hunk.id, to: destination)
        }
    }

    func validatedPlan() throws -> GGSplitPlan {
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

    func apply() async throws {
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
