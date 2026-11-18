import Foundation

extension RemoteSessionCatalog {
    /// A project as one list across machines: every worktree of one
    /// repository, whichever machine holds it.
    public struct ProjectGroup: Identifiable, Equatable, Sendable {
        public struct Row: Identifiable, Equatable, Sendable {
            public let hostID: HostID
            public let hostName: String
            public let worktree: RemoteWorktreeEntry
            public var id: String { "\(hostID.sortKey)|\(worktree.id)" }
        }

        /// Stable while machines come and go: `repo:` and the repository for
        /// a merged project, else the machine and its section.
        public let id: String
        public let title: String
        /// Newest first, across machines.
        public let rows: [Row]

        /// A machine a new session in this project can start on, by that
        /// machine's own id for the project, with its most recent worktree.
        public struct Placement: Equatable, Sendable {
            public let hostID: HostID
            public let projectId: String
            public let worktreeId: String
        }

        /// Each machine's project, the machine used most recently first.
        public var placements: [Placement] {
            var seen = Set<HostID>()
            // Rows are newest first, so a machine's first row is its newest worktree.
            return rows.compactMap { row in
                guard let projectId = row.worktree.projectId, seen.insert(row.hostID).inserted else { return nil }
                return Placement(hostID: row.hostID, projectId: projectId, worktreeId: row.worktree.id)
            }
        }

        /// The machines it spans, in row order.
        public var hostIDs: [HostID] {
            var seen = Set<HostID>()
            return rows.map(\.hostID).filter { seen.insert($0).inserted }
        }
    }

    /// Groups the machines' projects by repository. A project merges with
    /// others only through its repository key, and only when its machine
    /// has one project for that repository; anything it can't tell apart,
    /// such as a folder, a host too old to send keys, or two clones on one
    /// machine, stays its machine's own.
    public static func projects(from hosts: [Host]) -> [ProjectGroup] {
        struct Bucket {
            var title: String
            var titleRecency: Int64
            var rows: [ProjectGroup.Row] = []
        }
        var buckets: [String: Bucket] = [:]
        for host in hosts {
            let clones = Dictionary(grouping: host.sections.compactMap(\.repositoryKey), by: { $0 }).mapValues(\.count)
            for section in host.sections {
                let id = if let key = section.repositoryKey, clones[key] == 1 {
                    "repo:\(key)"
                } else {
                    "host:\(host.id.sortKey)|\(section.id)"
                }
                let recency = section.worktrees.map(\.recency).max() ?? 0
                var bucket = buckets[id] ?? Bucket(title: section.title, titleRecency: recency)
                // The busiest machine's name for the project wins.
                if (recency, bucket.title) > (bucket.titleRecency, section.title) {
                    bucket.title = section.title
                    bucket.titleRecency = recency
                }
                bucket.rows += section.worktrees.map { ProjectGroup.Row(hostID: host.id, hostName: host.name, worktree: $0) }
                buckets[id] = bucket
            }
        }
        return buckets.map { id, bucket in
            ProjectGroup(id: id, title: bucket.title, rows: bucket.rows.sorted {
                ($0.worktree.recency, $1.id) > ($1.worktree.recency, $0.id)
            })
        }.sorted {
            let (a, b) = ($0.rows.first?.worktree.recency ?? 0, $1.rows.first?.worktree.recency ?? 0)
            return a != b ? a > b : ($0.title, $0.id) < ($1.title, $1.id)
        }
    }
}

extension RemoteSessionDirectory {
    public static func filter(_ groups: [RemoteSessionCatalog.ProjectGroup], by filter: RemoteSessionFilter,
                              query: String) -> [RemoteSessionCatalog.ProjectGroup] {
        groups.filter { matches(title: $0.title, worktrees: $0.rows.map(\.worktree), filter: filter, query: query) }
    }

    public static func counts(_ groups: [RemoteSessionCatalog.ProjectGroup]) -> [RemoteSessionFilter: Int] {
        Dictionary(uniqueKeysWithValues: RemoteSessionFilter.allCases.map { f in
            (f, groups.filter { matches(title: $0.title, worktrees: $0.rows.map(\.worktree), filter: f, query: "") }.count)
        })
    }

    /// Rows waiting on the user first, then running ones, each group keeping
    /// the recency order `projects` gave it.
    public static func attentionFirst(_ rows: [RemoteSessionCatalog.ProjectGroup.Row]) -> [RemoteSessionCatalog.ProjectGroup.Row] {
        attentionFirst(rows, by: \.worktree)
    }
}
