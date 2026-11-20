import AlasCore
import Foundation
import Testing

@Suite @MainActor
struct PhoneRunTrackerTests {
    @Test func olderSnapshotCannotDropANewerLaunchOrRepeatACompletion() throws {
        let host = TestHost()
        let tracker = host.makeTracker()
        tracker.follow("build")
        let older = try host.snapshotRequestID()
        tracker.follow("checks")
        let newer = try host.snapshotRequestID()

        try host.snapshot(to: older, [run("build", .running)], on: tracker)
        try host.snapshot(to: newer, [run("build", .running), run("checks", .running)], on: tracker)
        let build = run("build", .finished(.succeeded))
        try host.events([build], on: tracker)
        try host.events([build, run("other", .finished(.failed(exitCode: 2))), run("checks", .finished(.failed(exitCode: 17)))], on: tracker)

        #expect(host.notices == [.init(id: "build", exitCode: 0), .init(id: "checks", exitCode: 17)])
    }

    @Test(arguments: [false, true])
    func runThatFinishesWhileDisconnectedNotifiesOnceOnReturn(relaunch: Bool) throws {
        let host = TestHost()
        let tracker = host.makeTracker()
        tracker.follow("checks")
        try host.snapshot(to: host.snapshotRequestID(), [run("checks", .running)], on: tracker)
        tracker.disconnect()

        let finished = run("checks", .finished(.failed(exitCode: 17)))
        try host.events([finished], on: tracker)
        #expect(host.notices.isEmpty)

        let reconnected = relaunch ? host.makeTracker() : tracker
        reconnected.refresh()
        let catchUp = try host.snapshotRequestID()
        try host.snapshot(to: catchUp, [finished], on: reconnected)
        reconnected.disconnect()

        let restored = host.makeTracker()
        restored.refresh()
        let latest = try host.snapshotRequestID()
        if latest != catchUp { try host.snapshot(to: latest, [finished], on: restored) }
        #expect(host.notices == [.init(id: "checks", exitCode: 17)])
    }

    private func run(_ id: String, _ status: RunStatus) -> RunRecord {
        RunRecord(id: id, scriptKey: "repo:\(id).sh", scriptName: id, worktreeID: "w", branch: "main",
                  target: RunExecutionTarget(host: nil, workingDirectory: "/repo"), status: status, startedAt: .distantPast)
    }

    @MainActor
    private final class TestHost {
        struct Notice: Equatable {
            let id: String
            let exitCode: Int32
        }

        private var pending: Set<String> = []
        private var requestID = 0
        private var outgoing: [OpaqueHostMessage] = []
        private(set) var notices: [Notice] = []
        private let generation = UUID()
        private var sequence: UInt64 = 0

        func makeTracker() -> PhoneRunTracker {
            PhoneRunTracker(pending: pending, nextRequestID: { [self] in
                requestID += 1
                return requestID
            }, send: { [self] in
                if case .host(let message) = $0 { outgoing.append(message) }
            }, save: { [self] in pending = $0 }, notify: { [self] id, _, exitCode in
                notices.append(Notice(id: id, exitCode: exitCode))
            })
        }

        func snapshotRequestID() throws -> Int {
            let ids = try snapshotRequestIDs()
            return try #require(ids.last)
        }

        func snapshotRequestIDs() throws -> [Int] {
            try outgoing.compactMap { message in
                let request = try JSONDecoder().decode(HostClientMessage.self, from: message.json)
                return request.request == .snapshot ? request.id : nil
            }
        }

        func snapshot(to id: Int, _ runs: [RunRecord], on tracker: PhoneRunTracker) throws {
            sequence += 1
            let cursor = HostCursor(generation: generation, sequence: sequence)
            let snapshot = HostSnapshot(cursor: cursor, projects: [], worktrees: [], workspaceCheckouts: [], runs: runs, sessions: [])
            try deliver(.response(id: id, result: .snapshot(snapshot: snapshot)), to: tracker)
        }

        func events(_ runs: [RunRecord], on tracker: PhoneRunTracker) throws {
            sequence += 1
            let cursor = HostCursor(generation: generation, sequence: sequence)
            try deliver(.events(events: runs.map(HostEvent.runChanged), cursor: cursor), to: tracker)
        }

        private func deliver(_ message: HostServerMessage, to tracker: PhoneRunTracker) throws {
            tracker.receive(.host(OpaqueHostMessage(json: try JSONEncoder().encode(message))))
        }
    }
}
