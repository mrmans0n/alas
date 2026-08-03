import Foundation

actor MissionPersistence {
    nonisolated let path: String

    private let busyTimeoutMilliseconds: Int32
    private var store: MissionStore?

    init(path: String = Paths.missionsDB.path, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    private func openedStore() throws -> MissionStore {
        if let store { return store }
        let opened = try MissionStore(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        store = opened
        return opened
    }

    func prepare() throws {
        _ = try openedStore()
    }

    func insert(_ aggregate: MissionAggregate, allowDuplicate: Bool = false) throws {
        try openedStore().insert(aggregate, allowDuplicate: allowDuplicate)
    }
    func aggregate(id: MissionID) throws -> MissionAggregate? { try openedStore().aggregate(id: id) }
    func list(includeCompleted: Bool) throws -> [MissionAggregate] { try openedStore().list(includeCompleted: includeCompleted) }
    func list(states: Set<MissionState>) throws -> [MissionAggregate] { try openedStore().list(states: states) }
    func activeMission(issueIdentity: MissionIssueIdentity) throws -> MissionAggregate? { try openedStore().activeMission(issueIdentity: issueIdentity) }

    func updateSetup(
        id: MissionID,
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        attentionReason: String?,
        event: MissionEvent
    ) throws {
        try openedStore().updateSetup(
            id: id,
            state: state,
            checkpoint: checkpoint,
            attentionReason: attentionReason,
            event: event
        )
    }

    func updateLeg(_ leg: MissionLeg, event: MissionEvent?) throws {
        try openedStore().updateLeg(leg, event: event)
    }

    func updateSetup(
        id: MissionID,
        leg: MissionLeg,
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        attentionReason: String?,
        event: MissionEvent
    ) throws {
        try openedStore().updateSetup(
            id: id,
            leg: leg,
            state: state,
            checkpoint: checkpoint,
            attentionReason: attentionReason,
            event: event
        )
    }

    @discardableResult
    func replaceIssueSnapshot(
        missionID: MissionID,
        snapshot: MissionIssueSnapshot,
        event: MissionEvent
    ) throws -> [MissionID] {
        try openedStore().replaceIssueSnapshot(missionID: missionID, snapshot: snapshot, event: event)
    }

    func updateIssueRefreshError(
        missionID: MissionID,
        refreshError: String,
        event: MissionEvent
    ) throws {
        try openedStore().updateIssueRefreshError(
            missionID: missionID,
            refreshError: refreshError,
            event: event
        )
    }

    func markReady(
        id: MissionID,
        reviewIdentity: MissionReviewIdentity?,
        event: MissionEvent
    ) throws {
        try openedStore().markReady(id: id, reviewIdentity: reviewIdentity, event: event)
    }

    func complete(id: MissionID, leg: MissionLeg? = nil, at: Date, event: MissionEvent) throws {
        try openedStore().complete(id: id, leg: leg, at: at, event: event)
    }
}
