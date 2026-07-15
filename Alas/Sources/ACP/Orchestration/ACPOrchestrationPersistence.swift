import Foundation

actor ACPOrchestrationPersistence {
    nonisolated let path: String

    private let busyTimeoutMilliseconds: Int32
    private var store: ACPOrchestrationStore?

    init(path: String = Paths.acpOrchestrationDB.path, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    private func openedStore() throws -> ACPOrchestrationStore {
        if let store { return store }
        let opened = try ACPOrchestrationStore(
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        store = opened
        return opened
    }

    func prepare() throws {
        _ = try openedStore()
    }

    func insert(_ record: ACPDelegationRecord) throws {
        try openedStore().insert(record)
    }

    func delegation(childSessionId: String) throws -> ACPDelegationRecord? {
        try openedStore().delegation(childSessionId: childSessionId)
    }

    func children(parentSessionId: String) throws -> [ACPDelegationRecord] {
        try openedStore().children(parentSessionId: parentSessionId)
    }
}
