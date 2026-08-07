import Foundation

/// What a followed tab is tracking. `.expression` is a git revision
/// expression re-resolved on each refresh; `.stackEntry` is a gg `GG-ID`
/// trailer, which survives the rebases and reorders that shift `HEAD~n`.
enum TrackedRevisionTarget: Equatable, Hashable, Sendable {
    case expression(String)
    case stackEntry(ggID: String)

    /// Stable key for persisted identity — review-session IDs, review-draft
    /// IDs, and commit-tab IDs are derived from it. For `.expression` it must
    /// stay byte-identical to the raw expression, which is what those IDs
    /// were built from before targets existed. Git refs cannot contain `:`,
    /// so the `gg:` namespace cannot collide with an expression.
    var identityKey: String {
        switch self {
        case .expression(let expression): expression
        case .stackEntry(let ggID): "gg:\(ggID)"
        }
    }

    /// What the revision row shows to the left of `-> <sha>`.
    var displayLabel: String {
        switch self {
        case .expression(let expression): expression
        case .stackEntry(let ggID): ggID
        }
    }

    var expressionValue: String? {
        guard case .expression(let expression) = self else { return nil }
        return expression
    }

    var ggID: String? {
        guard case .stackEntry(let ggID) = self else { return nil }
        return ggID
    }

    var isStackEntry: Bool { ggID != nil }

    /// Trims surrounding whitespace and rejects an empty payload.
    func normalized() -> TrackedRevisionTarget? {
        switch self {
        case .expression(let expression):
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .expression(trimmed)
        case .stackEntry(let ggID):
            let trimmed = ggID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .stackEntry(ggID: trimmed)
        }
    }
}

extension TrackedRevisionTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case expression
        case stackEntry = "stack-entry"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .expression: self = .expression(value)
        case .stackEntry: self = .stackEntry(ggID: value)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .expression(let expression):
            try container.encode(Kind.expression, forKey: .kind)
            try container.encode(expression, forKey: .value)
        case .stackEntry(let ggID):
            try container.encode(Kind.stackEntry, forKey: .kind)
            try container.encode(ggID, forKey: .value)
        }
    }
}
