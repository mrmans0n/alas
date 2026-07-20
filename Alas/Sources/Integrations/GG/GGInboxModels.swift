import Foundation

/// Decoded `gg inbox --json` snapshot (gg output version 1). Buckets are in
/// gg's priority order — most urgent first — which is also display order.
/// `stack_errors` are in-band per-stack failures (exit 0), not command errors.
struct GGInboxSnapshot: Equatable, Decodable {
    let version: Int
    let totalItems: Int
    let buckets: GGInboxBuckets
    let stackErrors: [GGInboxStackError]

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
    let readyToLand: [GGInboxEntry]
    let changesRequested: [GGInboxEntry]
    let blockedOnCi: [GGInboxEntry]
    let awaitingReview: [GGInboxEntry]
    let behindBase: [GGInboxEntry]
    let draft: [GGInboxEntry]
    /// Only serialized by gg with `--all`; absent in the default invocation.
    var merged: [GGInboxEntry] = []

    private enum CodingKeys: String, CodingKey {
        case readyToLand, changesRequested, blockedOnCi, awaitingReview, behindBase, draft, merged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readyToLand = try c.decode([GGInboxEntry].self, forKey: .readyToLand)
        changesRequested = try c.decode([GGInboxEntry].self, forKey: .changesRequested)
        blockedOnCi = try c.decode([GGInboxEntry].self, forKey: .blockedOnCi)
        awaitingReview = try c.decode([GGInboxEntry].self, forKey: .awaitingReview)
        behindBase = try c.decode([GGInboxEntry].self, forKey: .behindBase)
        draft = try c.decode([GGInboxEntry].self, forKey: .draft)
        merged = try c.decodeIfPresent([GGInboxEntry].self, forKey: .merged) ?? []
    }
}

struct GGInboxEntry: Equatable, Decodable {
    let stackName: String
    let position: Int
    let sha: String
    let title: String
    let prNumber: Int
    let prUrl: String
    let ciStatus: String?
    let behindBase: Int?
}

struct GGInboxStackError: Equatable, Decodable {
    let stackName: String
    let error: String
}

/// Presentation metadata for the six rendered buckets, in gg's priority
/// order. `merged` is decodable but intentionally not rendered (no --all in v1).
enum GGInboxBucket: CaseIterable, Equatable {
    case readyToLand, changesRequested, blockedOnCi, awaitingReview, behindBase, draft

    var title: String {
        switch self {
        case .readyToLand:      return "Ready to land"
        case .changesRequested: return "Changes requested"
        case .blockedOnCi:      return "Blocked on CI"
        case .awaitingReview:   return "Awaiting review"
        case .behindBase:       return "Behind base"
        case .draft:            return "Draft"
        }
    }

    var themeToken: String {
        switch self {
        case .readyToLand:                    return "add"
        case .changesRequested, .blockedOnCi: return "warn"
        case .awaitingReview, .behindBase, .draft: return "fg-dim"
        }
    }

    func entries(in buckets: GGInboxBuckets) -> [GGInboxEntry] {
        switch self {
        case .readyToLand:      return buckets.readyToLand
        case .changesRequested: return buckets.changesRequested
        case .blockedOnCi:      return buckets.blockedOnCi
        case .awaitingReview:   return buckets.awaitingReview
        case .behindBase:       return buckets.behindBase
        case .draft:            return buckets.draft
        }
    }
}
