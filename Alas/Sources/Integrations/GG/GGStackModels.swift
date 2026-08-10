import Foundation

/// Errors from the gg CLI integration. Mirrors `CodeHostProviderError`
/// shape but scoped to the gg tool, which is not a forge provider.
enum GGServiceError: Error, Equatable {
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
    var userMessage: String {
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
    static func map(exitCode: Int32, stderr: String) -> GGServiceError {
        if exitCode == 127 { return .cliMissing }
        return .commandFailed(stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Decoded envelope of `gg ls --json` / `gg log --json`. When the current
/// branch is a stack, gg emits `{"version":1,"stack":{...}}`; off-stack it
/// emits an all-stacks shape with no `stack` key, which decodes here as
/// `stack == nil`.
struct GGStackSnapshot: Decodable, Equatable {
    static let supportedSchemaVersion = 1
    let version: Int
    let stack: GGStack?
    let operationID: String?

    init(version: Int, stack: GGStack?, operationID: String? = nil) {
        self.version = version
        self.stack = stack
        self.operationID = operationID
    }

    private enum CodingKeys: String, CodingKey {
        case version, stack
        case operationID = "operationId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        stack = try container.decodeIfPresent(GGStack.self, forKey: .stack)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
    }

    var identity: GGStackIdentity? {
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

    static func decode(fromJSON data: Data) throws -> GGStackSnapshot {
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

struct GGStack: Decodable, Equatable {
    let name: String
    let base: String
    let totalCommits: Int
    let syncedCommits: Int
    let currentPosition: Int?
    let behindBase: Int?
    let entries: [GGStackEntry]

    var summary: GGStackSummary {
        GGStackSummary(
            merged: entries.filter { $0.prState == .merged }.count,
            total: totalCommits
        )
    }

    /// gg reports abbreviated SHAs; Alas commit lists carry full 40-char
    /// SHAs. Match on whichever is the prefix of the other.
    func entry(matchingCommitSHA sha: String) -> GGStackEntry? {
        entries.first { sha.hasPrefix($0.sha) || $0.sha.hasPrefix(sha) }
    }

    func projectCommits(_ infosBySHA: [String: CommitInfo]) throws -> [CommitInfo] {
        try entries.sorted { $0.position > $1.position }.map { entry in
            guard let info = infosBySHA.first(where: {
                $0.key.hasPrefix(entry.sha) || entry.sha.hasPrefix($0.key)
            })?.value else {
                throw GGStackCommitProjectionError.missingCommit(sha: entry.sha)
            }
            return info
        }
    }

    func relation(for entry: GGStackEntry) -> GGStackCommitRelation {
        guard entries.contains(where: { $0.id == entry.id }),
              let currentPosition,
              entries.contains(where: { $0.position == currentPosition && $0.isCurrent })
        else { return .unknown }
        if entry.position > currentPosition { return .aboveCurrent }
        if entry.position == currentPosition, entry.isCurrent { return .current }
        return .belowCurrent
    }

    func currentPositionIndicator(for entry: GGStackEntry) -> GGCurrentPositionIndicator? {
        guard relation(for: entry) == .current,
              let currentPosition,
              currentPosition < totalCommits,
              totalCommits == entries.count
        else { return nil }
        return GGCurrentPositionIndicator(
            text: "Current · \(currentPosition) of \(totalCommits)",
            accessibilityLabel: "Current GG commit, position \(currentPosition) of \(totalCommits)"
        )
    }
}

enum GGStackCommitRelation: Equatable {
    case aboveCurrent
    case current
    case belowCurrent
    case unknown
}

struct GGCurrentPositionIndicator: Equatable {
    let text: String
    let accessibilityLabel: String
}

enum GGStackCommitProjectionError: Error, Equatable, LocalizedError {
    case missingCommit(sha: String)

    var errorDescription: String? {
        "One or more GG stack commits are unavailable locally."
    }
}

enum GGPRState: String, Equatable {
    case open, merged, closed, draft
}

enum GGCIStatus: String, Equatable {
    case pending, running, success, failed, canceled, unknown
}

struct GGStackEntry: Decodable, Equatable, Identifiable {
    /// Stable identity across rebases/amends: the GG-ID trailer when
    /// present, the (rewriting) SHA otherwise.
    var id: String { ggId ?? sha }
    let position: Int
    let sha: String
    let title: String
    let ggId: String?
    let ggParent: String?
    let prNumber: Int?
    let prState: GGPRState?
    let approved: Bool
    let ciStatus: GGCIStatus?
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case position, sha, title, ggId, ggParent, prNumber, prState,
             approved, ciStatus, isCurrent
    }

    init(
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
    init(from decoder: Decoder) throws {
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
struct GGStackSummary: Equatable {
    let merged: Int
    let total: Int
}
