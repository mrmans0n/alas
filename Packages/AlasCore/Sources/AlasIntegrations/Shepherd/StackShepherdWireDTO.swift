import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Agent-facing JSON of the `stack_ship` MCP tool. Snake_cased on the wire by
/// `ReviewCommentWireDTO.jsonLine`'s key strategy.
public struct StackShipResultWire: Encodable, Equatable, Sendable {
    public struct Entry: Encodable, Equatable, Sendable {
        public var position: Int
        public var entryId: String
        public var title: String
        public var number: Int
        public var url: String
        public var state: String
        public var draft: Bool

        public init(position: Int, entryId: String, title: String, number: Int, url: String, state: String, draft: Bool) {
            self.position = position
            self.entryId = entryId
            self.title = title
            self.number = number
            self.url = url
            self.state = state
            self.draft = draft
        }
    }

    public struct Shepherd: Encodable, Equatable, Sendable {
        public var autoFix: Bool

        public init(autoFix: Bool) {
            self.autoFix = autoFix
        }
    }

    public var stack: String
    public var base: String
    public var provider: String
    /// Bottom-up.
    public var entries: [Entry]
    public var uncommittedChanges: Bool
    public var shepherd: Shepherd

    public init(stack: String, base: String, provider: String, entries: [Entry], uncommittedChanges: Bool, shepherd: Shepherd) {
        self.stack = stack
        self.base = base
        self.provider = provider
        self.entries = entries
        self.uncommittedChanges = uncommittedChanges
        self.shepherd = shepherd
    }
}

extension StackShipResultWire {
    public init(record: StackShepherdRecord, requests: [Int: ReviewRequest], uncommittedChanges: Bool) {
        self.init(
            stack: record.id.stackName,
            base: record.base,
            provider: record.remote.kind.rawValue,
            entries: record.openEntries.compactMap { entry in
                guard let request = requests[entry.requestNumber] else { return nil }
                return Entry(
                    position: entry.position, entryId: entry.entryID, title: entry.title,
                    number: request.number, url: request.url.absoluteString,
                    state: request.state.rawValue, draft: request.isDraft
                )
            },
            uncommittedChanges: uncommittedChanges,
            shepherd: Shepherd(autoFix: record.autoFix)
        )
    }
}

/// `pr_status` for a gg stack. Optional fields encode as explicit `null` so
/// agents always see the same keys.
public struct StackStatusWire: Encodable, Equatable, Sendable {
    public struct Entry: Encodable, Equatable, Sendable {
        public var position: Int
        public var entryId: String
        public var title: String
        /// Null for an entry gg has not published yet.
        public var pullRequest: PRStatusWire.PullRequest?
        /// The shepherd's phase for this entry; null when not shepherded.
        public var phase: String?

        public init(position: Int, entryId: String, title: String, pullRequest: PRStatusWire.PullRequest?, phase: String?) {
            self.position = position
            self.entryId = entryId
            self.title = title
            self.pullRequest = pullRequest
            self.phase = phase
        }

        public enum CodingKeys: String, CodingKey {
            case position, entryId, title, pullRequest, phase
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(position, forKey: .position)
            try container.encode(entryId, forKey: .entryId)
            try container.encode(title, forKey: .title)
            try container.encode(pullRequest, forKey: .pullRequest)
            try container.encode(phase, forKey: .phase)
        }
    }

    public struct Stack: Encodable, Equatable, Sendable {
        public var name: String
        public var base: String
        /// Bottom-up.
        public var entries: [Entry]

        public init(name: String, base: String, entries: [Entry]) {
            self.name = name
            self.base = base
            self.entries = entries
        }
    }

    public struct Shepherd: Encodable, Equatable, Sendable {
        public var phase: String
        public var autoFix: Bool
        public var fixAttempts: Int
        public var maxFixAttempts: Int
        public var readyToLand: Bool
        public var rulesSource: String

        public init(phase: String, autoFix: Bool, fixAttempts: Int, maxFixAttempts: Int, readyToLand: Bool, rulesSource: String) {
            self.phase = phase
            self.autoFix = autoFix
            self.fixAttempts = fixAttempts
            self.maxFixAttempts = maxFixAttempts
            self.readyToLand = readyToLand
            self.rulesSource = rulesSource
        }
    }

    public var stack: Stack
    public var shepherd: Shepherd?

    public init(stack: Stack, shepherd: Shepherd?) {
        self.stack = stack
        self.shepherd = shepherd
    }

    public enum CodingKeys: String, CodingKey {
        case stack, shepherd
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stack, forKey: .stack)
        try container.encode(shepherd, forKey: .shepherd)
    }
}

extension StackStatusWire.Shepherd {
    public init(record: StackShepherdRecord, readyToLand: Bool, rules: ShepherdRules) {
        self.init(
            phase: PRStatusWire.Shepherd.wireName(record.phase),
            autoFix: record.autoFix,
            fixAttempts: record.fixAttempts,
            maxFixAttempts: record.fixAttemptBudget,
            readyToLand: readyToLand,
            rulesSource: PRStatusWire.Shepherd.wireName(rules.source)
        )
    }
}
