import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPSessionDiscoveryCapabilities: Equatable, Sendable {
    public let canLoad: Bool
    public let canResume: Bool
    public let canFork: Bool
    public let canDelete: Bool

    public var canOpenRemoteSession: Bool { canLoad || canResume }

    public init(canLoad: Bool, canResume: Bool, canFork: Bool, canDelete: Bool) {
        self.canLoad = canLoad
        self.canResume = canResume
        self.canFork = canFork
        self.canDelete = canDelete
    }
}

public struct ACPDiscoveredSession: Identifiable, Equatable, Sendable {
    public var id: String { remoteSessionId }

    /// The Alas worktree the session runs in: the one whose path is `cwd`.
    /// Nil for a session outside every Alas worktree of the project, such as
    /// a worktree the agent made itself; such a row can be browsed but not
    /// opened.
    public let worktreeId: String?
    public let agentId: String
    public let remoteSessionId: String
    public let cwd: String
    public var title: String
    public let updatedAt: Date?
    public let additionalDirectories: [String]
    public var localSessionId: String?
    /// Session index row fields, when the agent sent them.
    public var index: ACPSessionIndexRowMeta?

    public var isAlreadyInAlas: Bool { localSessionId != nil }
    public var isCompatibleWithAlas: Bool { additionalDirectories.isEmpty }
    public var isArchived: Bool { index?.archived == true }
    /// The list order key of the session index: last prompt, else last activity.
    public var lastActivity: Date? {
        index?.lastPromptAt.flatMap(ACPSessionIndexDates.parse) ?? updatedAt
    }

    public init(
        worktreeId: String?,
        agentId: String,
        remoteSessionId: String,
        cwd: String,
        title: String,
        updatedAt: Date?,
        additionalDirectories: [String],
        localSessionId: String?,
        index: ACPSessionIndexRowMeta? = nil
    ) {
        self.worktreeId = worktreeId
        self.agentId = agentId
        self.remoteSessionId = remoteSessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.additionalDirectories = additionalDirectories
        self.localSessionId = localSessionId
        self.index = index
    }
}

public enum ACPSessionIndexDates {
    public static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// How a session's cwd is matched to an Alas worktree path.
public enum ACPSessionBrowserPaths {
    /// Adapters report agent-side paths: an SSH worktree's real path rather
    /// than its `/.alas-remote/<host>/…` id, and a local cwd with symlinks
    /// resolved (`/private/var/…` for `/var/…`). Both sides are keyed that
    /// way. `context` is the browsing worktree's path: under an SSH worktree
    /// a plain path is the remote host's, so it is never resolved against
    /// this Mac's file system.
    public static func key(_ path: String, context: String) -> String {
        if let remote = RemotePath.split(path) {
            return URL(fileURLWithPath: remote.realPath).standardizedFileURL.path
        }
        if RemotePath.split(context) != nil {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// When a live change started being turned into rows: the local actions
/// completed and the list reads started by then.
public struct ACPSessionBrowserStamp: Equatable, Sendable {
    public var localActions: Int
    public var listReads: Int

    public init(localActions: Int = 0, listReads: Int = 0) {
        self.localActions = localActions
        self.listReads = listReads
    }
}

/// What the session browser shows: the browsing worktree alone or every
/// linked worktree of its repository, and active or archived sessions.
public struct ACPSessionBrowserFilter: Equatable, Sendable {
    public var includeLinkedWorktrees: Bool
    public var showArchived: Bool

    public init(includeLinkedWorktrees: Bool = false, showArchived: Bool = false) {
        self.includeLinkedWorktrees = includeLinkedWorktrees
        self.showArchived = showArchived
    }

    package var listOptions: ACPSessionIndexListOptions {
        .init(includeWorktrees: includeLinkedWorktrees, archived: showArchived ? .archived : .unarchived)
    }
}

/// Applies `_session/list/changes` to the rows the browser shows.
public enum ACPSessionBrowserReducer {
    /// A changed row replaces the listed row in place, so selection and
    /// scrolling stay put. A new row is inserted by last activity, newest
    /// first. A row that no longer matches the archive filter leaves, and so
    /// does every removed id. Ids stay unique.
    /// Without the linked-worktree scope, a row of another worktree leaves
    /// too: subscriptions always cover every linked worktree.
    public static func applying(
        changed: [ACPDiscoveredSession],
        removed: [String],
        to rows: [ACPDiscoveredSession],
        filter: ACPSessionBrowserFilter,
        browsingWorktreeId: String?
    ) -> [ACPDiscoveredSession] {
        let removedIds = Set(removed)
        var result = rows.filter { !removedIds.contains($0.remoteSessionId) }
        for row in changed where !removedIds.contains(row.remoteSessionId) {
            let existing = result.firstIndex { $0.remoteSessionId == row.remoteSessionId }
            let inScope = filter.includeLinkedWorktrees || row.worktreeId == browsingWorktreeId
            guard row.isArchived == filter.showArchived, inScope else {
                if let existing { result.remove(at: existing) }
                continue
            }
            if let existing {
                result[existing] = row
            } else {
                let date = row.lastActivity ?? .distantFuture
                let index = result.firstIndex { ($0.lastActivity ?? .distantPast) < date } ?? result.endIndex
                result.insert(row, at: index)
            }
        }
        return result
    }

    /// Live rows of sessions whose local action completed after the rows
    /// started being read (`stamp`) may predate that action: they are left
    /// out, and the next relist brings the agent's current state.
    public static func droppingRows(
        _ rows: [ACPDiscoveredSession],
        predating stamp: ACPSessionBrowserStamp,
        lastLocalAction: [String: Int]
    ) -> [ACPDiscoveredSession] {
        rows.filter { (lastLocalAction[$0.remoteSessionId] ?? Int.min) <= stamp.localActions }
    }

    /// The parts of a live change no list page has superseded. A page that
    /// started after the change began being read (read index above
    /// `stamp.listReads`) and showed a session holds newer data for it, so
    /// the change's row or removal for that session is dropped. Sessions such
    /// a page did not show keep the change, as does every session when the
    /// newer read failed.
    public static func unsuperseded(
        changed: [ACPDiscoveredSession],
        removed: [String],
        stamp: ACPSessionBrowserStamp,
        pageReadIndex: [String: Int]
    ) -> (changed: [ACPDiscoveredSession], removed: [String]) {
        func current(_ id: String) -> Bool { (pageReadIndex[id] ?? 0) <= stamp.listReads }
        return (changed.filter { current($0.remoteSessionId) }, removed.filter(current))
    }

    /// Listed rows a new first page lacks without proving them
    /// gone: tied with or older than the page's oldest row, or undated. They
    /// may have moved to a later page, so the pages after the boundary are
    /// read to settle them.
    public static func unsettledCandidates(
        firstPage: [ACPDiscoveredSession],
        listedBefore: Set<String>,
        rows: [ACPDiscoveredSession]
    ) -> Set<String> {
        let present = Set(firstPage.map(\.remoteSessionId))
        let oldest = firstPage.compactMap(\.lastActivity).min()
        return Set(rows.filter { row in
            guard listedBefore.contains(row.remoteSessionId), !present.contains(row.remoteSessionId) else { return false }
            guard let oldest, let activity = row.lastActivity else { return true }
            return activity <= oldest
        }.map(\.remoteSessionId))
    }

    /// Merges a freshly read first page. A listed row the new page lacks is
    /// gone (a missed removal) when the new page is the whole list, or when
    /// it is newer than the new page's oldest row; an older one may just be
    /// on a later page, so it stays unless the boundary scan settled it.
    /// `confirmedGone` holds rows that reading past the page boundary did not
    /// find (see `unsettledCandidates`).
    public static func reconciling(
        firstPage: [ACPDiscoveredSession],
        hasMorePages: Bool,
        listedBefore: Set<String>,
        rows: [ACPDiscoveredSession],
        filter: ACPSessionBrowserFilter,
        browsingWorktreeId: String?,
        confirmedGone: Set<String> = []
    ) -> [ACPDiscoveredSession] {
        let present = Set(firstPage.map(\.remoteSessionId))
        let oldest = firstPage.compactMap(\.lastActivity).min()
        let vanished = rows.filter { row in
            guard listedBefore.contains(row.remoteSessionId), !present.contains(row.remoteSessionId) else { return false }
            guard hasMorePages, !confirmedGone.contains(row.remoteSessionId) else { return true }
            guard let oldest, let activity = row.lastActivity else { return false }
            return activity > oldest
        }
        return applying(
            changed: firstPage,
            removed: vanished.map(\.remoteSessionId),
            to: rows,
            filter: filter,
            browsingWorktreeId: browsingWorktreeId
        )
    }
}

public enum ACPSessionRestoreOperation: Equatable, Sendable {
    case resume
    case loadWithRecovery
    case loadStrict
    case unavailable
}

public enum ACPSessionRestorePolicy: Sendable {
    public static func operation(
        origin: ACPSessionOrigin,
        canLoad: Bool,
        canResume: Bool,
        hasLocalTranscript: Bool = false
    ) -> ACPSessionRestoreOperation {
        switch origin {
        case .alasCreated:
            return canResume ? .resume : .loadWithRecovery
        case .agentImported, .agentForked:
            if hasLocalTranscript, canResume { return .resume }
            if canLoad { return .loadStrict }
            if canResume { return .resume }
            return .unavailable
        }
    }
}

public enum ACPSessionDiscoveryError: LocalizedError, Equatable, Sendable {
    case noLaunchSpec(String)
    case setupRequired(String)
    case setupFailed(String)
    case listingUnsupported
    case deletionUnsupported
    case renameUnsupported
    case archiveUnsupported

    public var errorDescription: String? {
        switch self {
        case .noLaunchSpec(let agentId):
            return "No ACP launch configuration is available for \(agentId)."
        case .setupRequired(let reason), .setupFailed(let reason):
            return reason
        case .listingUnsupported:
            return "This agent does not support session browsing."
        case .deletionUnsupported:
            return "This agent does not support deleting session history."
        case .renameUnsupported:
            return "This agent does not support renaming sessions."
        case .archiveUnsupported:
            return "This agent does not support archiving sessions."
        }
    }
}

public enum ACPSessionAttachError: LocalizedError, Equatable, Sendable {
    case remoteSessionUnsupported

    public var errorDescription: String? {
        "This agent cannot reopen the selected session."
    }
}
