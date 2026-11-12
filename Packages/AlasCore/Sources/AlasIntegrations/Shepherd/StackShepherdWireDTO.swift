import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Agent-facing JSON of the `stack_ship` MCP tool. Snake_cased on the wire by
/// `ReviewCommentWireDTO.jsonLine`'s key strategy; decoded back for the card
/// of a ship that finished after Alas had replied.
public struct StackShipResultWire: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
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

    /// An entry the user chose not to publish yet.
    public struct HeldBackEntry: Codable, Equatable, Sendable {
        public var position: Int
        public var entryId: String
        public var title: String

        public init(position: Int, entryId: String, title: String) {
            self.position = position
            self.entryId = entryId
            self.title = title
        }
    }

    public struct Shepherd: Codable, Equatable, Sendable {
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
    /// Bottom-up; left local by the user's choice in the Ship popover.
    public var heldBack: [HeldBackEntry]
    public var uncommittedChanges: Bool
    /// The stack was rebased onto its base before the sync, dropping entries
    /// that had already landed.
    public var restacked: Bool
    public var shepherd: Shepherd

    public init(
        stack: String, base: String, provider: String, entries: [Entry], heldBack: [HeldBackEntry],
        uncommittedChanges: Bool, restacked: Bool, shepherd: Shepherd
    ) {
        self.stack = stack
        self.base = base
        self.provider = provider
        self.entries = entries
        self.heldBack = heldBack
        self.uncommittedChanges = uncommittedChanges
        self.restacked = restacked
        self.shepherd = shepherd
    }
}

extension StackShipResultWire {
    public init(
        record: StackShepherdRecord, requests: [Int: ReviewRequest], heldBack: [GGStackEntry],
        uncommittedChanges: Bool, restacked: Bool
    ) {
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
            heldBack: heldBack.map { HeldBackEntry(position: $0.position, entryId: $0.id, title: $0.title) },
            uncommittedChanges: uncommittedChanges,
            restacked: restacked,
            shepherd: Shepherd(autoFix: record.autoFix)
        )
    }
}

/// What a `stack_ship` is doing while it runs.
public enum StackShipPhase: String, Encodable, Sendable {
    /// Listing the stack and checking origin for entries that already landed.
    case checking
    /// `gg rebase` dropping landed entries.
    case rebasing
    /// `gg sync` started, before it reports linting or pushing.
    case syncing
    /// gg's configured lint, run on every entry before the sync pushes.
    case linting
    /// Pushing entries and opening or updating their requests.
    case pushing
    /// Reading the published pull/merge requests and binding the shepherd.
    case reading
}

/// A running `stack_ship`'s phase, and inside gg sync the entry it is on.
public struct StackShipProgress: Equatable, Sendable {
    public var phase: StackShipPhase
    /// The entry being linted or pushed.
    public var position: Int?
    /// How many entries the sync lints or pushes.
    public var totalEntries: Int?

    public init(phase: StackShipPhase, position: Int? = nil, totalEntries: Int? = nil) {
        self.phase = phase
        self.position = position
        self.totalEntries = totalEntries
    }

    /// Follows one `gg sync --jsonl` event.
    public mutating func apply(_ event: GGSyncEvent) {
        switch event {
        case .start(let total):
            totalEntries = total
        case .lintStarted(let total):
            self = .init(phase: .linting, totalEntries: total)
        case .lintEntryStarted(let position, _):
            self.phase = .linting
            self.position = position
        case .entryStarted(let position, _), .pushStarted(let position):
            self.phase = .pushing
            self.position = position
        case .lintEntryDone, .pushDone, .prCreated, .prUpdated, .prSkippedClosed, .summary, .error:
            break
        }
    }

    /// "linting 3/6", "pushing 2/6", or the bare phase.
    public var label: String {
        guard let position, phase == .linting || phase == .pushing else { return phase.rawValue }
        return totalEntries.map { "\(phase.rawValue) \(position)/\($0)" } ?? "\(phase.rawValue) entry \(position)"
    }
}

/// `stack_ship`'s reply, and `pr_status`'s, while a ship still runs after
/// Alas replied: the call returns before a slow gg sync (lint can take
/// minutes) outlasts the agent's tool timeout.
public struct StackShipProgressWire: Encodable, Equatable, Sendable {
    public var status = "in_progress"
    public var phase: StackShipPhase
    /// e.g. "linting 3/6".
    public var progress: String
    public var elapsedSeconds: Int
    public var message: String

    public init(progress: StackShipProgress, elapsedSeconds: Int, message: String) {
        self.phase = progress.phase
        self.progress = progress.label
        self.elapsedSeconds = elapsedSeconds
        self.message = message
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
        /// An entry landed while the local stack still holds its commit:
        /// `stack_ship` rebases it away and publishes the rest.
        public var restackNeeded: Bool
        public var rulesSource: String

        public init(
            phase: String, autoFix: Bool, fixAttempts: Int, maxFixAttempts: Int,
            readyToLand: Bool, restackNeeded: Bool, rulesSource: String
        ) {
            self.phase = phase
            self.autoFix = autoFix
            self.fixAttempts = fixAttempts
            self.maxFixAttempts = maxFixAttempts
            self.readyToLand = readyToLand
            self.restackNeeded = restackNeeded
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
    public init(record: StackShepherdRecord, readyToLand: Bool, restackNeeded: Bool, rules: ShepherdRules) {
        self.init(
            phase: PRStatusWire.Shepherd.wireName(record.phase),
            autoFix: record.autoFix,
            fixAttempts: record.fixAttempts,
            maxFixAttempts: record.fixAttemptBudget,
            readyToLand: readyToLand,
            restackNeeded: restackNeeded,
            rulesSource: PRStatusWire.Shepherd.wireName(rules.source)
        )
    }
}
