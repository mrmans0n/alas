import Foundation

struct AttentionLiveSignal: Equatable, Sendable {
    let eventID: UUID
    let signal: AttentionSignal
    let isCurrentlyActive: Bool
}

enum AttentionItemPresentation: Equatable, Sendable {
    case live
    case historical
}

struct AttentionResolvedWorktree: Equatable, Sendable {
    let id: String
    let projectID: String
    let display: AttentionWorktreeDisplaySnapshot
}

struct AttentionWorktree {
    let worktree: Worktree
    let project: ProjectConfig

    init(worktree: Worktree, project: ProjectConfig) {
        self.worktree = worktree
        self.project = project
    }

    var resolved: AttentionResolvedWorktree {
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

struct AttentionItem: Equatable, Sendable {
    let eventID: UUID
    let sourceKey: AttentionSourceKey
    let owner: AttentionWorktreeIdentity
    let kind: AttentionKind
    let title: String
    let body: String?
    let occurredAt: Date
    let presentation: AttentionItemPresentation
    let jumpTarget: AttentionJumpTarget
    let display: AttentionWorktreeDisplaySnapshot
    let worktree: AttentionResolvedWorktree?
    let acknowledgedAt: Date?
}

struct AttentionAggregation: Equatable, Sendable {
    let items: [AttentionItem]
    let history: [AttentionItem]
    let unresolvedCount: Int
    let unresolvedCountByProject: [String: Int]
}

extension AttentionWorktreeIdentity {
    static func make(worktree: Worktree, project: ProjectConfig) -> Self {
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

struct AttentionWorktreeResolver {
    private let aliases: [AttentionWorktreeIdentity: AttentionWorktreeIdentity]
    private let worktreesByIdentity: [AttentionWorktreeIdentity: AttentionResolvedWorktree]

    init(
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

    func resolve(_ owner: AttentionWorktreeIdentity) -> AttentionResolvedWorktree? {
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

enum AttentionSignalAggregator {
    static func aggregate(
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
            let acknowledgment = document.acknowledgments[event.id]
            if event.requiresAction, acknowledgment == nil {
                let live = activeSignals[event.id]
                items.append(item(for: event, live: live, acknowledgment: nil, resolver: resolver))
            } else {
                history.append(item(for: event, live: nil, acknowledgment: acknowledgment, resolver: resolver))
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
        acknowledgment: AttentionAcknowledgment?,
        resolver: AttentionWorktreeResolver
    ) -> AttentionItem {
        let signal = live?.signal
        let owner = signal?.owner ?? event.owner
        let worktree = resolver.resolve(owner)
        let presentation: AttentionItemPresentation = live == nil ? .historical : .live
        return AttentionItem(
            eventID: event.id,
            sourceKey: signal?.sourceKey ?? event.sourceKey,
            owner: owner,
            kind: signal?.kind ?? event.kind,
            title: live == nil ? historicalTitle(for: event) : signal!.title,
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
