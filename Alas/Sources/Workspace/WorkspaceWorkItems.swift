import Foundation

enum WorkspaceWorkItemError: Error, Equatable, LocalizedError, Sendable {
    case checkoutMissing
    case itemMissing
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .checkoutMissing:
            "Workspace Checkout was not found."
        case .itemMissing:
            "Work Item was not found."
        case .refreshFailed(let message):
            message
        }
    }
}

protocol WorkspaceWorkItemRefreshing: Sendable {
    func refresh(_ snapshot: IssueSnapshot, hostingMemberID: UUID?) async throws -> IssueSnapshot
}

struct NoopWorkspaceWorkItemRefresher: WorkspaceWorkItemRefreshing {
    func refresh(_ snapshot: IssueSnapshot, hostingMemberID: UUID?) async throws -> IssueSnapshot { snapshot }
}

enum WorkspaceWorkItemHostingCandidate: Equatable, Sendable {
    case exact(UUID)
    case ambiguous([UUID])
    case unavailable
}

struct WorkspaceWorkItemController: Sendable {
    let store: WorkspaceStore
    let refresher: any WorkspaceWorkItemRefreshing

    init(store: WorkspaceStore, refresher: any WorkspaceWorkItemRefreshing = NoopWorkspaceWorkItemRefresher()) {
        self.store = store
        self.refresher = refresher
    }

    func attach(_ snapshot: IssueSnapshot, to checkoutID: UUID, hostingMemberID: UUID?) async throws {
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceWorkItemError.checkoutMissing
            }
            state.checkouts[index].workItems.append(WorkItemSnapshot(snapshot: snapshot, hostingMemberID: hostingMemberID))
        }
    }

    func refresh(_ itemID: UUID, in checkoutID: UUID) async throws {
        guard let checkout = await store.checkout(id: checkoutID) else {
            throw WorkspaceWorkItemError.checkoutMissing
        }
        guard let current = checkout.workItems.first(where: { $0.id == itemID }) else {
            throw WorkspaceWorkItemError.itemMissing
        }

        do {
            let refreshed = try await refresher.refresh(current.snapshot, hostingMemberID: current.hostingMemberID)
            try await store.mutate { state in
                guard let path = itemPath(itemID: itemID, checkoutID: checkoutID, in: state) else {
                    throw WorkspaceWorkItemError.itemMissing
                }
                state.checkouts[path.checkout].workItems[path.item].snapshot = refreshed
                state.checkouts[path.checkout].workItems[path.item].lastGoodSnapshot = refreshed
                state.checkouts[path.checkout].workItems[path.item].capturedAt = refreshed.capturedAt
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            try await store.mutate { state in
                guard let path = itemPath(itemID: itemID, checkoutID: checkoutID, in: state) else {
                    throw WorkspaceWorkItemError.itemMissing
                }
                state.checkouts[path.checkout].workItems[path.item].snapshot.refreshError = message
            }
        }
    }

    func replace(_ itemID: UUID, in checkoutID: UUID, with snapshot: IssueSnapshot, hostingMemberID: UUID?) async throws {
        try await store.mutate { state in
            guard let path = itemPath(itemID: itemID, checkoutID: checkoutID, in: state) else {
                throw WorkspaceWorkItemError.itemMissing
            }
            state.checkouts[path.checkout].workItems[path.item] = WorkItemSnapshot(
                id: itemID,
                snapshot: snapshot,
                hostingMemberID: hostingMemberID
            )
        }
    }

    func edit(_ itemID: UUID, in checkoutID: UUID, title: String, body: String) async throws {
        try await store.mutate { state in
            guard let path = itemPath(itemID: itemID, checkoutID: checkoutID, in: state) else {
                throw WorkspaceWorkItemError.itemMissing
            }
            let item = state.checkouts[path.checkout].workItems[path.item]
            let edited = IssueSnapshot(
                identity: item.snapshot.identity,
                canonicalURL: item.snapshot.canonicalURL,
                providerLabel: item.snapshot.providerLabel,
                displayReference: item.snapshot.displayReference,
                repositoryLocator: item.snapshot.repositoryLocator,
                title: title,
                body: body,
                state: item.snapshot.state,
                labels: item.snapshot.labels,
                assignees: item.snapshot.assignees,
                providerUpdatedAt: item.snapshot.providerUpdatedAt,
                capturedAt: Date(),
                refreshError: nil,
                contentOrigin: item.snapshot.contentOrigin,
                isEditable: item.snapshot.isEditable,
                isRefreshable: item.snapshot.isRefreshable
            )
            state.checkouts[path.checkout].workItems[path.item].snapshot = edited
            state.checkouts[path.checkout].workItems[path.item].lastGoodSnapshot = edited
        }
    }

    func detach(_ itemID: UUID, from checkoutID: UUID) async throws {
        try await store.mutate { state in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceWorkItemError.checkoutMissing
            }
            state.checkouts[checkoutIndex].workItems.removeAll { $0.id == itemID }
        }
    }

    static func hostingCandidates(
        for issue: IssueSnapshot,
        members: [WorkspaceCheckoutMember],
        projects: [ProjectConfig],
        remotes: [String: [String]]
    ) -> [WorkspaceWorkItemHostingCandidate] {
        guard let locator = issue.repositoryLocator else { return [.unavailable] }
        let knownProjectIDs = Set(projects.map(\.id))
        let matches = members.compactMap { member -> UUID? in
            guard knownProjectIDs.contains(member.projectID) else { return nil }
            let memberRemotes = remotes[member.projectID] ?? []
            return memberRemotes.contains(where: { remoteMatches($0, locator: locator) }) ? member.id : nil
        }
        switch matches.count {
        case 0:
            return [.unavailable]
        case 1:
            return [.exact(matches[0])]
        default:
            return [.ambiguous(matches)]
        }
    }

    private func itemPath(itemID: UUID, checkoutID: UUID, in state: WorkspaceStateFile) -> (checkout: Int, item: Int)? {
        guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
              let itemIndex = state.checkouts[checkoutIndex].workItems.firstIndex(where: { $0.id == itemID })
        else { return nil }
        return (checkoutIndex, itemIndex)
    }

    private static func remoteMatches(_ remote: String, locator: IssueRepositoryLocator) -> Bool {
        guard let parsed = ParsedRemote(remote) else { return false }
        return parsed.host.caseInsensitiveCompare(locator.host) == .orderedSame
            && parsed.slug.caseInsensitiveCompare(locator.repositorySlug.stripGitSuffix()) == .orderedSame
    }
}

private struct ParsedRemote {
    var host: String
    var slug: String

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !url.path.isEmpty {
            self.host = host
            self.slug = String(url.path.drop(while: { $0 == "/" })).stripGitSuffix()
            return
        }
        guard trimmed.hasPrefix("git@"),
              let colon = trimmed.firstIndex(of: ":")
        else { return nil }
        self.host = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<colon])
        self.slug = String(trimmed[trimmed.index(after: colon)...]).stripGitSuffix()
    }
}

private extension String {
    func stripGitSuffix() -> String {
        hasSuffix(".git") ? String(dropLast(4)) : self
    }
}
