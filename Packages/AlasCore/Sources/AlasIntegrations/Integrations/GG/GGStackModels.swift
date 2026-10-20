import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Errors from the gg CLI integration. Mirrors `CodeHostProviderError`
/// shape but scoped to the gg tool, which is not a forge provider.
public enum GGServiceError: Error, Equatable, Sendable {
    case cliMissing
    case commandFailed(stderr: String)
    case malformedOutput(String)
    case unsupportedSchema(Int)
    case immutableTargets(message: String)
    case dirtyWorkingTree(message: String)
    case staleTarget(message: String)
    case staleSplitPlan(message: String)
    case pausedConflict(message: String)
    case partialMutation(message: String)
    case undoRefused(message: String, hint: String?)
}

extension GGServiceError {
    /// User-facing message for the stack drawer's error strip.
    public var userMessage: String {
        switch self {
        case .cliMissing: return "gg is not installed."
        case .commandFailed(let stderr): return stderr.isEmpty ? "gg command failed." : stderr
        case .malformedOutput(let message): return message
        case .unsupportedSchema(let version):
            return "Unsupported gg output (schema \(version)). Update gg and try again."
        case .immutableTargets(let message),
             .dirtyWorkingTree(let message),
             .staleTarget(let message),
             .staleSplitPlan(let message),
             .pausedConflict(let message),
             .partialMutation(let message):
            return message
        case .undoRefused(let message, let hint):
            guard let hint, !hint.isEmpty else { return message }
            return "\(message)\n\(hint)"
        }
    }

    /// Canonical exit-code mapping shared by every gg invocation path.
    /// Callers only invoke this for non-zero exits.
    public static func map(exitCode: Int32, stderr: String) -> GGServiceError {
        if exitCode == 127 { return .cliMissing }
        return .commandFailed(stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Decoded envelope of `gg ls --json` / `gg log --json`. When the current
/// branch is a stack, gg emits `{"version":1,"stack":{...}}`; off-stack it
/// emits an all-stacks shape with no `stack` key, which decodes here as
/// `stack == nil`.
public struct GGStackSnapshot: Decodable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    public let version: Int
    public let stack: GGStack?
    public let operationID: String?

    public init(version: Int, stack: GGStack?, operationID: String? = nil) {
        self.version = version
        self.stack = stack
        self.operationID = operationID
    }

    private enum CodingKeys: String, CodingKey {
        case version, stack
        case operationID = "operationId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        stack = try container.decodeIfPresent(GGStack.self, forKey: .stack)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
    }

    public var identity: GGStackIdentity? {
        guard let stack,
              let head = stack.entries.max(by: { $0.position < $1.position })
        else { return nil }
        return GGStackIdentity(
            stackName: stack.name,
            base: stack.base,
            headSHA: head.sha,
            operationID: operationID
        )
    }

    public static func decode(fromJSON data: Data) throws -> GGStackSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot: GGStackSnapshot
        do {
            snapshot = try decoder.decode(GGStackSnapshot.self, from: data)
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
        guard snapshot.version <= supportedSchemaVersion else {
            throw GGServiceError.unsupportedSchema(snapshot.version)
        }
        return snapshot
    }
}

public struct GGStack: Decodable, Equatable, Sendable {
    public let name: String
    public let base: String
    public let totalCommits: Int
    public let syncedCommits: Int
    public let currentPosition: Int?
    public let behindBase: Int?
    public let entries: [GGStackEntry]

    public var summary: GGStackSummary {
        GGStackSummary(
            merged: entries.filter { $0.prState == .merged }.count,
            total: totalCommits
        )
    }

    /// gg reports abbreviated SHAs; Alas commit lists carry full 40-char
    /// SHAs. Match on whichever is the prefix of the other.
    public func entry(matchingCommitSHA sha: String) -> GGStackEntry? {
        entries.first { sha.hasPrefix($0.sha) || $0.sha.hasPrefix(sha) }
    }

    public func mergingRemoteMetadata(from remote: GGStack?) -> GGStack {
        guard let remote, name == remote.name else { return self }
        return GGStack(
            name: name,
            base: base,
            totalCommits: totalCommits,
            syncedCommits: syncedCommits,
            currentPosition: currentPosition,
            behindBase: behindBase,
            entries: entries.map { entry in
                guard let match = remote.entries.first(where: {
                    if let ggId = entry.ggId {
                        return $0.ggId == ggId && (entry.prNumber == nil || $0.prNumber == nil || entry.prNumber == $0.prNumber)
                    }
                    if let prNumber = entry.prNumber { return $0.prNumber == prNumber }
                    return entry.sha.hasPrefix($0.sha) || $0.sha.hasPrefix(entry.sha)
                })
                else { return entry }
                return GGStackEntry(
                    position: entry.position,
                    sha: entry.sha,
                    title: entry.title,
                    ggId: entry.ggId,
                    ggParent: entry.ggParent,
                    prNumber: entry.prNumber ?? match.prNumber,
                    prState: match.prState,
                    approved: match.approved,
                    ciStatus: match.ciStatus,
                    isCurrent: entry.isCurrent
                )
            }
        )
    }

    public func projectCommits(_ infosBySHA: [String: CommitInfo]) throws -> [CommitInfo] {
        guard hasValidEntryShape,
              infosBySHA.allSatisfy({ !$0.key.isEmpty && $0.key == $0.value.sha })
        else {
            throw GGStackCommitProjectionError.malformedStack
        }

        var resolvedSHAs: Set<String> = []
        return try entries.sorted { $0.position > $1.position }.map { entry in
            let matches = infosBySHA.filter {
                $0.key.hasPrefix(entry.sha) || entry.sha.hasPrefix($0.key)
            }
            guard !matches.isEmpty else {
                throw GGStackCommitProjectionError.missingCommit(sha: entry.sha)
            }
            guard matches.count == 1,
                  let match = matches.first,
                  resolvedSHAs.insert(match.key).inserted
            else {
                throw GGStackCommitProjectionError.malformedStack
            }
            let info = match.value
            return info
        }
    }

    public func relation(for entry: GGStackEntry) -> GGStackCommitRelation {
        guard entries.contains(entry),
              let currentEntry = validatedCurrentEntry
        else { return .unknown }
        if entry.position > currentEntry.position { return .aboveCurrent }
        if entry == currentEntry { return .current }
        return .belowCurrent
    }

    public func currentPositionIndicator(for entry: GGStackEntry) -> GGCurrentPositionIndicator? {
        guard let currentEntry = validatedCurrentEntry,
              entry == currentEntry,
              currentEntry.position < totalCommits
        else { return nil }
        return GGCurrentPositionIndicator(
            text: "Current · \(currentEntry.position) of \(totalCommits)",
            accessibilityLabel: "Current GG commit, position \(currentEntry.position) of \(totalCommits)"
        )
    }

    private var hasValidEntryShape: Bool {
        guard totalCommits >= 0,
              totalCommits == entries.count,
              Set(entries.map(\.position)) == Set(entries.indices.map { $0 + 1 }),
              entries.allSatisfy({ !$0.sha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(entries.map(\.sha)).count == entries.count
        else { return false }
        return true
    }

    private var validatedCurrentEntry: GGStackEntry? {
        guard hasValidEntryShape,
              let currentPosition,
              currentPosition >= 1,
              currentPosition <= totalCommits
        else { return nil }
        let currentEntries = entries.filter(\.isCurrent)
        guard currentEntries.count == 1,
              currentEntries[0].position == currentPosition
        else { return nil }
        return currentEntries[0]
    }

    public init(name: String, base: String, totalCommits: Int, syncedCommits: Int, currentPosition: Int?, behindBase: Int?, entries: [GGStackEntry]) {
        self.name = name
        self.base = base
        self.totalCommits = totalCommits
        self.syncedCommits = syncedCommits
        self.currentPosition = currentPosition
        self.behindBase = behindBase
        self.entries = entries
    }
}

public enum GGStackCommitRelation: Equatable, Sendable {
    case aboveCurrent
    case current
    case belowCurrent
    case unknown
}

public struct GGCurrentPositionIndicator: Equatable, Sendable {
    public let text: String
    public let accessibilityLabel: String

    public init(text: String, accessibilityLabel: String) {
        self.text = text
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum GGStackCommitProjectionError: Error, Equatable, LocalizedError, Sendable {
    case missingCommit(sha: String)
    case malformedStack

    public var errorDescription: String? {
        switch self {
        case .missingCommit:
            return "One or more GG stack commits are unavailable locally."
        case .malformedStack:
            return "GG returned incomplete or inconsistent stack metadata."
        }
    }
}

public enum GGPRState: String, Equatable, Sendable {
    case open, merged, closed, draft
}

public enum GGCIStatus: String, Equatable, Sendable {
    case pending, running, success, failed, canceled, unknown
}

public struct GGStackEntry: Decodable, Equatable, Identifiable, Sendable {
    /// Stable identity across rebases/amends: the GG-ID trailer when
    /// present, the (rewriting) SHA otherwise.
    public var id: String { ggId ?? sha }
    public let position: Int
    public let sha: String
    public let title: String
    public let ggId: String?
    public let ggParent: String?
    public let prNumber: Int?
    public let prState: GGPRState?
    public let approved: Bool
    public let ciStatus: GGCIStatus?
    public let isCurrent: Bool

    public enum CodingKeys: String, CodingKey, Sendable {
        case position, sha, title, ggId, ggParent, prNumber, prState,
             approved, ciStatus, isCurrent
    }

    public init(
        position: Int,
        sha: String,
        title: String,
        ggId: String? = nil,
        ggParent: String? = nil,
        prNumber: Int? = nil,
        prState: GGPRState? = nil,
        approved: Bool = false,
        ciStatus: GGCIStatus? = nil,
        isCurrent: Bool = false
    ) {
        self.position = position
        self.sha = sha
        self.title = title
        self.ggId = ggId
        self.ggParent = ggParent
        self.prNumber = prNumber
        self.prState = prState
        self.approved = approved
        self.ciStatus = ciStatus
        self.isCurrent = isCurrent
    }

    // Tolerant decode: unknown enum strings and future fields must not
    // fail the whole snapshot — fall back per-field instead.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Int.self, forKey: .position)
        sha = try c.decode(String.self, forKey: .sha)
        title = try c.decode(String.self, forKey: .title)
        ggId = try? c.decode(String.self, forKey: .ggId)
        ggParent = try? c.decode(String.self, forKey: .ggParent)
        prNumber = try? c.decode(Int.self, forKey: .prNumber)
        prState = (try? c.decode(String.self, forKey: .prState))
            .flatMap(GGPRState.init(rawValue:))
        approved = (try? c.decode(Bool.self, forKey: .approved)) ?? false
        ciStatus = (try? c.decode(String.self, forKey: .ciStatus))
            .flatMap(GGCIStatus.init(rawValue:))
        isCurrent = (try? c.decode(Bool.self, forKey: .isCurrent)) ?? false
    }
}

/// Compact merged/total pair for the sidebar worktree badge.
public struct GGStackSummary: Equatable, Sendable {
    public let merged: Int
    public let total: Int
    public var isRemoteStateKnown: Bool = true

    public init(merged: Int, total: Int, isRemoteStateKnown: Bool = true) {
        self.merged = merged
        self.total = total
        self.isRemoteStateKnown = isRemoteStateKnown
    }
}
