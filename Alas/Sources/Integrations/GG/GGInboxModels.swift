import Foundation

/// Decoded `gg inbox --json` snapshot (gg output version 1). Buckets are in
/// gg's priority order — most urgent first — which is also display order.
/// `stack_errors` are in-band per-stack failures (exit 0), not command errors.
struct GGInboxSnapshot: Equatable, Decodable {
    let version: Int
    let totalItems: Int
    let buckets: GGInboxBuckets
    let stackErrors: [GGInboxStackError]

    init(version: Int = 1, totalItems: Int, buckets: GGInboxBuckets, stackErrors: [GGInboxStackError]) {
        self.version = version
        self.totalItems = totalItems
        self.buckets = buckets
        self.stackErrors = stackErrors
    }

    static func decode(fromJSON data: Data) throws -> GGInboxSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(GGInboxSnapshot.self, from: data)
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }
}

struct GGInboxBuckets: Equatable, Decodable {
    var refreshFailed: [GGInboxEntry]
    var readyToLand: [GGInboxEntry]
    var changesRequested: [GGInboxEntry]
    var blockedOnCi: [GGInboxEntry]
    var awaitingReview: [GGInboxEntry]
    var behindBase: [GGInboxEntry]
    var draft: [GGInboxEntry]
    /// Only serialized by gg with `--all`; absent in the default invocation.
    var merged: [GGInboxEntry]

    init(
        refreshFailed: [GGInboxEntry] = [],
        readyToLand: [GGInboxEntry] = [],
        changesRequested: [GGInboxEntry] = [],
        blockedOnCi: [GGInboxEntry] = [],
        awaitingReview: [GGInboxEntry] = [],
        behindBase: [GGInboxEntry] = [],
        draft: [GGInboxEntry] = [],
        merged: [GGInboxEntry] = []
    ) {
        self.refreshFailed = refreshFailed
        self.readyToLand = readyToLand
        self.changesRequested = changesRequested
        self.blockedOnCi = blockedOnCi
        self.awaitingReview = awaitingReview
        self.behindBase = behindBase
        self.draft = draft
        self.merged = merged
    }

    private enum CodingKeys: String, CodingKey {
        case refreshFailed, readyToLand, changesRequested, blockedOnCi, awaitingReview, behindBase, draft, merged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshFailed = try c.decode([GGInboxEntry].self, forKey: .refreshFailed)
        readyToLand = try c.decode([GGInboxEntry].self, forKey: .readyToLand)
        changesRequested = try c.decode([GGInboxEntry].self, forKey: .changesRequested)
        blockedOnCi = try c.decode([GGInboxEntry].self, forKey: .blockedOnCi)
        awaitingReview = try c.decode([GGInboxEntry].self, forKey: .awaitingReview)
        behindBase = try c.decode([GGInboxEntry].self, forKey: .behindBase)
        draft = try c.decode([GGInboxEntry].self, forKey: .draft)
        merged = try c.decodeIfPresent([GGInboxEntry].self, forKey: .merged) ?? []
    }

    mutating func insert(_ entry: GGInboxEntry, into bucket: GGInboxBucket) {
        var entries = bucket.entries(in: self)
        let identity = (entry.stackName, entry.position, entry.prNumber)
        if let index = entries.firstIndex(where: { ($0.stackName, $0.position, $0.prNumber) == identity }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { ($0.stackName, $0.position, $0.sha) < ($1.stackName, $1.position, $1.sha) }
        switch bucket {
        case .refreshFailed: refreshFailed = entries
        case .readyToLand: readyToLand = entries
        case .changesRequested: changesRequested = entries
        case .blockedOnCi: blockedOnCi = entries
        case .awaitingReview: awaitingReview = entries
        case .behindBase: behindBase = entries
        case .draft: draft = entries
        }
    }
}

struct GGInboxEntry: Equatable, Decodable {
    let stackName: String
    let position: Int
    let sha: String
    let title: String
    let prNumber: Int
    let prUrl: String?
    let ciStatus: String?
    let behindBase: Int?
    let refreshError: String?

    init(
        stackName: String,
        position: Int,
        sha: String,
        title: String,
        prNumber: Int,
        prUrl: String? = nil,
        ciStatus: String? = nil,
        behindBase: Int? = nil,
        refreshError: String? = nil
    ) {
        self.stackName = stackName
        self.position = position
        self.sha = sha
        self.title = title
        self.prNumber = prNumber
        self.prUrl = prUrl?.nilIfEmpty
        self.ciStatus = ciStatus
        self.behindBase = behindBase
        self.refreshError = refreshError
    }

    private enum CodingKeys: String, CodingKey {
        case stackName, position, sha, title, prNumber, prUrl, ciStatus, behindBase, refreshError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stackName = try c.decode(String.self, forKey: .stackName)
        position = try c.decode(Int.self, forKey: .position)
        sha = try c.decode(String.self, forKey: .sha)
        title = try c.decode(String.self, forKey: .title)
        prNumber = try c.decode(Int.self, forKey: .prNumber)
        prUrl = try c.decodeIfPresent(String.self, forKey: .prUrl)?.nilIfEmpty
        ciStatus = try c.decodeIfPresent(String.self, forKey: .ciStatus)
        behindBase = try c.decodeIfPresent(Int.self, forKey: .behindBase)
        refreshError = try c.decodeIfPresent(String.self, forKey: .refreshError)
    }
}

struct GGInboxStackError: Equatable, Decodable {
    let stackName: String
    let error: String
}

/// Presentation metadata for the rendered buckets, in gg's priority order.
enum GGInboxBucket: String, CaseIterable, Equatable, Decodable {
    case refreshFailed = "refresh_failed"
    case readyToLand = "ready_to_land"
    case changesRequested = "changes_requested"
    case blockedOnCi = "blocked_on_ci"
    case awaitingReview = "awaiting_review"
    case behindBase = "behind_base"
    case draft

    var title: String {
        switch self {
        case .refreshFailed: return "Refresh failed"
        case .readyToLand: return "Ready to land"
        case .changesRequested: return "Changes requested"
        case .blockedOnCi: return "Blocked on CI"
        case .awaitingReview: return "Awaiting review"
        case .behindBase: return "Behind base"
        case .draft: return "Draft"
        }
    }

    var themeToken: String {
        switch self {
        case .readyToLand: return "add"
        case .refreshFailed, .changesRequested, .blockedOnCi: return "warn"
        case .awaitingReview, .behindBase, .draft: return "fg-dim"
        }
    }

    func entries(in buckets: GGInboxBuckets) -> [GGInboxEntry] {
        switch self {
        case .refreshFailed: return buckets.refreshFailed
        case .readyToLand: return buckets.readyToLand
        case .changesRequested: return buckets.changesRequested
        case .blockedOnCi: return buckets.blockedOnCi
        case .awaitingReview: return buckets.awaitingReview
        case .behindBase: return buckets.behindBase
        case .draft: return buckets.draft
        }
    }
}

struct GGInboxEntryEvent: Equatable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket?
    let remoteState: String
    let entry: GGInboxEntry
}

struct GGInboxEntryErrorEvent: Equatable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket
    let failedEntry: GGInboxEntry
}

enum GGInboxEvent: Equatable {
    case start(totalCandidates: Int, totalStackErrors: Int)
    case stackError(GGInboxStackError)
    case entry(GGInboxEntryEvent)
    case entryError(GGInboxEntryErrorEvent)
    case summary(GGInboxSnapshot)
    case error(message: String)

    static func decode(line: String) throws -> GGInboxEvent {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(GGInboxEventEnvelope.self, from: data)
            guard envelope.version == 1 else {
                throw GGServiceError.unsupportedSchema(envelope.version)
            }
            guard envelope.command == "inbox" else {
                throw GGServiceError.malformedOutput("Expected gg inbox event, got \(envelope.command).")
            }
            switch envelope.event {
            case "start": return try decoder.decode(GGInboxStartPayload.self, from: data).event
            case "stack_error": return try decoder.decode(GGInboxStackErrorPayload.self, from: data).event
            case "entry": return try decoder.decode(GGInboxEntryPayload.self, from: data).event
            case "entry_error": return try decoder.decode(GGInboxEntryErrorPayload.self, from: data).event
            case "summary": return .summary(try decoder.decode(GGInboxSnapshot.self, from: data))
            case "error": return .error(message: try decoder.decode(GGInboxFatalPayload.self, from: data).message)
            default: throw GGServiceError.malformedOutput("Unknown gg inbox event: \(envelope.event)")
            }
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }
}

enum GGInboxSupport {
    static let minimumVersion = SemanticVersion(major: 0, minor: 9, patch: 12)

    static func isSupported(version: String?) -> Bool {
        guard let version, let parsed = SemanticVersion(parsing: version) else { return false }
        return parsed >= minimumVersion
    }
}

private struct GGInboxEventEnvelope: Decodable {
    let event: String
    let version: Int
    let command: String
}

private struct GGInboxStartPayload: Decodable {
    let totalCandidates: Int
    let totalStackErrors: Int

    var event: GGInboxEvent { .start(totalCandidates: totalCandidates, totalStackErrors: totalStackErrors) }
}

private struct GGInboxStackErrorPayload: Decodable {
    let stackName: String
    let error: String

    var event: GGInboxEvent { .stackError(GGInboxStackError(stackName: stackName, error: error)) }
}

private struct GGInboxEntryPayload: Decodable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket?
    let remoteState: String
    let entry: GGInboxEntry

    var event: GGInboxEvent {
        .entry(GGInboxEntryEvent(
            completed: completed,
            totalCandidates: totalCandidates,
            included: included,
            bucket: bucket,
            remoteState: remoteState,
            entry: entry
        ))
    }
}

private struct GGInboxEntryErrorPayload: Decodable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket
    let entry: GGInboxEntry
    let error: String

    var event: GGInboxEvent {
        .entryError(GGInboxEntryErrorEvent(
            completed: completed,
            totalCandidates: totalCandidates,
            included: included,
            bucket: bucket,
            failedEntry: GGInboxEntry(
                stackName: entry.stackName,
                position: entry.position,
                sha: entry.sha,
                title: entry.title,
                prNumber: entry.prNumber,
                prUrl: nil,
                ciStatus: nil,
                behindBase: entry.behindBase,
                refreshError: error
            )
        ))
    }
}

private struct GGInboxFatalPayload: Decodable {
    let message: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
