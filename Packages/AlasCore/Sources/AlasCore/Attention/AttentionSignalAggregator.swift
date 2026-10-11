import Foundation

public struct AttentionLiveSignal: Equatable, Sendable {
    public let eventID: UUID
    public let signal: AttentionSignal
    public let isCurrentlyActive: Bool

    public init(eventID: UUID, signal: AttentionSignal, isCurrentlyActive: Bool) {
        self.eventID = eventID
        self.signal = signal
        self.isCurrentlyActive = isCurrentlyActive
    }
}

public enum AttentionItemPresentation: Equatable, Sendable {
    case live
    case unverified
    case historical
}

public struct AttentionResolvedWorktree: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let display: AttentionWorktreeDisplaySnapshot

    public init(id: String, projectID: String, display: AttentionWorktreeDisplaySnapshot) {
        self.id = id
        self.projectID = projectID
        self.display = display
    }
}

public struct AttentionWorktree: Sendable {
    public let worktree: Worktree
    public let project: ProjectConfig

    public init(worktree: Worktree, project: ProjectConfig) {
        self.worktree = worktree
        self.project = project
    }

    public var resolved: AttentionResolvedWorktree {
        AttentionResolvedWorktree(
            id: worktree.id,
            projectID: project.id,
            display: AttentionWorktreeDisplaySnapshot(
                projectName: project.name,
                branch: worktree.branch,
                path: worktree.path.standardizedFileURL.path,
                host: project.host
            )
        )
    }
}

public struct AttentionItem: Equatable, Sendable {
    public let eventID: UUID
    public let sourceKey: AttentionSourceKey
    public let owner: AttentionWorktreeIdentity
    public let kind: AttentionKind
    public let title: String
    public let body: String?
    public let occurredAt: Date
    public let presentation: AttentionItemPresentation
    public let jumpTarget: AttentionJumpTarget
    public let display: AttentionWorktreeDisplaySnapshot
    public let worktree: AttentionResolvedWorktree?
    public let acknowledgedAt: Date?

    public init(eventID: UUID, sourceKey: AttentionSourceKey, owner: AttentionWorktreeIdentity, kind: AttentionKind, title: String, body: String?, occurredAt: Date, presentation: AttentionItemPresentation, jumpTarget: AttentionJumpTarget, display: AttentionWorktreeDisplaySnapshot, worktree: AttentionResolvedWorktree?, acknowledgedAt: Date?) {
        self.eventID = eventID
        self.sourceKey = sourceKey
        self.owner = owner
        self.kind = kind
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
        self.presentation = presentation
        self.jumpTarget = jumpTarget
        self.display = display
        self.worktree = worktree
        self.acknowledgedAt = acknowledgedAt
    }
}

public struct AttentionAggregation: Equatable, Sendable {
    public let items: [AttentionItem]
    public let history: [AttentionItem]
    public let unresolvedCount: Int
    public let unresolvedCountByProject: [String: Int]

    public init(items: [AttentionItem], history: [AttentionItem], unresolvedCount: Int, unresolvedCountByProject: [String: Int]) {
        self.items = items
        self.history = history
        self.unresolvedCount = unresolvedCount
        self.unresolvedCountByProject = unresolvedCountByProject
    }
}

extension AttentionWorktreeIdentity {
    public static func make(worktree: Worktree, project: ProjectConfig) -> Self {
        let host = project.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location: Location = if let host, !host.isEmpty {
            .ssh(host)
        } else {
            .local
        }
        let lineageID = worktree.lineageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            projectID: project.id,
            location: location,
            lineageID: lineageID?.isEmpty == false ? lineageID : nil,
            legacyPath: lineageID?.isEmpty == false ? nil : worktree.path.standardizedFileURL.path
        )
    }
}

public struct AttentionWorktreeResolver: Sendable {
    private let aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity]
    private let worktreesByIdentity: [AttentionWorktreeIdentity: AttentionResolvedWorktree]

    public init(
        worktrees: [AttentionWorktree],
        aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity]
    ) {
        self.aliases = aliases
        worktreesByIdentity = Dictionary(
            uniqueKeysWithValues: worktrees.map {
                (AttentionWorktreeIdentity.make(worktree: $0.worktree, project: $0.project), $0.resolved)
            }
        )
    }

    public func resolve(_ owner: AttentionWorktreeIdentity) -> AttentionResolvedWorktree? {
        var current = owner
        var visited: Set<AttentionWorktreeIdentity> = []
        while visited.insert(current).inserted {
            if let worktree = worktreesByIdentity[current] {
                return worktree
            }
            guard let alias = aliases[current] else { break }
            current = alias
        }
        return nil
    }
}

public enum AttentionSignalAggregator: Sendable {
    public static func aggregate(
        liveSignals: [AttentionLiveSignal],
        document: AttentionDocument,
        worktrees: [AttentionWorktree]
    ) -> AttentionAggregation {
        let resolver = AttentionWorktreeResolver(worktrees: worktrees, aliases: document.aliases)
        let activeSignals = Dictionary(
            liveSignals.lazy.filter(\.isCurrentlyActive).map { ($0.eventID, $0) },
            uniquingKeysWith: { latest, _ in latest }
        )
        var items: [AttentionItem] = []
        var history: [AttentionItem] = []

        for event in document.events {
            let observation = document.observations[event.sourceKey]
            let isCurrent = observation?.isActive == true && observation?.eventID == event.id
            let live = isCurrent ? activeSignals[event.id] : nil
            let presentation: AttentionItemPresentation = isCurrent
                ? (live == nil ? .unverified : .live)
                : .historical
            let acknowledgment = document.acknowledgments[event.id]
            let currentItem = item(
                for: event, live: live, presentation: presentation,
                acknowledgment: acknowledgment, resolver: resolver
            )
            if isCurrent, event.requiresAction, currentItem.kind.requiresAction, acknowledgment == nil {
                items.append(currentItem)
            } else {
                history.append(currentItem)
            }
        }

        items.sort(by: newestFirst)
        history.sort(by: newestFirst)
        let unresolvedCountByProject = Dictionary(grouping: items, by: { $0.owner.projectID })
            .mapValues(\.count)
        return AttentionAggregation(
            items: items,
            history: history,
            unresolvedCount: items.count,
            unresolvedCountByProject: unresolvedCountByProject
        )
    }

    private static func item(
        for event: AttentionEvent,
        live: AttentionLiveSignal?,
        presentation: AttentionItemPresentation,
        acknowledgment: AttentionAcknowledgment?,
        resolver: AttentionWorktreeResolver
    ) -> AttentionItem {
        let signal = live?.signal
        let owner = signal?.owner ?? event.owner
        let worktree = resolver.resolve(owner)
        return AttentionItem(
            eventID: event.id,
            sourceKey: signal?.sourceKey ?? event.sourceKey,
            owner: owner,
            kind: signal?.kind ?? event.kind,
            title: presentation == .historical ? historicalTitle(for: event) : signal?.title ?? event.title,
            body: signal?.body ?? event.body,
            occurredAt: event.occurredAt,
            presentation: presentation,
            jumpTarget: signal?.jumpTarget ?? event.jumpTarget,
            display: worktree?.display ?? event.display,
            worktree: worktree,
            acknowledgedAt: acknowledgment?.acknowledgedAt
        )
    }

    private static func historicalTitle(for event: AttentionEvent) -> String {
        event.kind.historicalTitle(from: event.title)
    }

    private static func newestFirst(_ lhs: AttentionItem, _ rhs: AttentionItem) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return lhs.eventID.uuidString > rhs.eventID.uuidString
    }
}
