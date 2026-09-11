import Foundation
import Testing
@testable import Alas

struct RunRecordStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func target(host: String? = nil, cwd: String = "/wt") -> RunExecutionTarget {
        RunExecutionTarget(host: host, workingDirectory: cwd)
    }

    private func record(
        id: String = "run-1",
        scriptKey: String = "repo:dev.sh",
        worktreeID: String = "wt-1",
        branch: String = "main",
        host: String? = nil,
        endpoint: URL? = nil,
        status: RunStatus = .starting
    ) -> RunRecord {
        RunRecord(
            id: id,
            scriptKey: scriptKey,
            scriptName: "Dev",
            worktreeID: worktreeID,
            branch: branch,
            target: target(host: host),
            endpoint: endpoint,
            status: status,
            startedAt: epoch
        )
    }

    // MARK: - Lifecycle

    @Test func beginThenRunThenFinishTracksOneRun() {
        var store = RunRecordStore()
        #expect(store.begin(record()) == nil)
        store.markRunning(runID: "run-1", sessionID: "session-1")
        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .running)
        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.sessionID == "session-1")

        store.finish(runID: "run-1", outcome: .succeeded, at: epoch.addingTimeInterval(12))

        let finished = store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")
        #expect(finished?.status == .finished(.succeeded))
        #expect(finished?.duration == 12)
        #expect(store.activeRecords.isEmpty)
    }

    @Test func finishRecordsFailureExitCodeAndOutputLink() {
        var store = RunRecordStore()
        store.begin(record())
        store.markRunning(runID: "run-1", sessionID: "session-1")

        store.finish(runID: "run-1", outcome: .failed(exitCode: 42), at: epoch, failureID: "failure-1")

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.failed(exitCode: 42)))
        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.failureID == "failure-1")
    }

    // MARK: - Launch races

    /// A restart replaces the record; the superseded run's monitor may still
    /// be in flight and must not write its outcome over the new run.
    @Test func supersededRunCannotFinishTheRunThatReplacedIt() {
        var store = RunRecordStore()
        store.begin(record(id: "run-1"))
        store.markRunning(runID: "run-1", sessionID: "session-1")
        store.begin(record(id: "run-2"))
        store.markRunning(runID: "run-2", sessionID: "session-2")

        store.finish(runID: "run-1", outcome: .succeeded, at: epoch.addingTimeInterval(5))

        let current = store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")
        #expect(current?.id == "run-2")
        #expect(current?.status == .running)
    }

    @Test func supersededRunCannotMarkTheReplacementUnknown() {
        var store = RunRecordStore()
        store.begin(record(id: "run-1"))
        store.begin(record(id: "run-2"))
        store.markRunning(runID: "run-2", sessionID: "session-2")

        store.markLostObservation(runID: "run-1", at: epoch)

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .running)
    }

    @Test func rollbackRestoresTheDisplacedOutcome() {
        var store = RunRecordStore()
        store.begin(record(id: "run-1"))
        store.finish(runID: "run-1", outcome: .failed(exitCode: 1), at: epoch)
        let displaced = store.begin(record(id: "run-2"))

        store.rollback(runID: "run-2", to: displaced)

        let current = store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")
        #expect(current?.id == "run-1")
        #expect(current?.status == .finished(.failed(exitCode: 1)))
    }

    @Test func rollbackOfASupersededRunLeavesTheCurrentRunAlone() {
        var store = RunRecordStore()
        let displaced = store.begin(record(id: "run-1"))
        store.begin(record(id: "run-2"))

        store.rollback(runID: "run-1", to: displaced)

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.id == "run-2")
    }

    @Test func rollbackWithNoPreviousRunClearsTheSlot() {
        var store = RunRecordStore()
        let displaced = store.begin(record(id: "run-1"))

        store.rollback(runID: "run-1", to: displaced)

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh") == nil)
        #expect(store.byWorktree["wt-1"] == nil)
    }

    // MARK: - Honest outcomes

    @Test func lostObservationNeverReportsSuccess() {
        var store = RunRecordStore()
        store.begin(record())
        store.markRunning(runID: "run-1", sessionID: "session-1")

        store.markLostObservation(runID: "run-1", at: epoch.addingTimeInterval(3))

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.unknown))
    }

    /// The command reported an exit status; closing its shell afterwards is
    /// not new information about the command.
    @Test func closingTheShellAfterCompletionKeepsTheObservedOutcome() {
        var store = RunRecordStore()
        store.begin(record())
        store.markRunning(runID: "run-1", sessionID: "session-1")
        store.finish(runID: "run-1", outcome: .succeeded, at: epoch)

        store.markLostObservation(runID: "run-1", at: epoch.addingTimeInterval(60))
        store.markStopped(worktreeID: "wt-1", scriptKey: "repo:dev.sh", at: epoch.addingTimeInterval(60))

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.succeeded))
    }

    @Test func stopWinsOverLaterLostObservation() {
        var store = RunRecordStore()
        store.begin(record())
        store.markRunning(runID: "run-1", sessionID: "session-1")

        store.markStopped(worktreeID: "wt-1", scriptKey: "repo:dev.sh", at: epoch.addingTimeInterval(4))
        store.markLostObservation(runID: "run-1", at: epoch.addingTimeInterval(6))

        let current = store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")
        #expect(current?.status == .finished(.stopped))
        #expect(current?.finishedAt == epoch.addingTimeInterval(4))
    }

    // MARK: - Worktree isolation

    @Test func recordsDoNotLeakAcrossWorktrees() {
        var store = RunRecordStore()
        store.begin(record(id: "run-a", worktreeID: "wt-1"))
        store.markRunning(runID: "run-a", sessionID: "session-a")
        store.begin(record(id: "run-b", worktreeID: "wt-2"))
        store.markRunning(runID: "run-b", sessionID: "session-b")

        store.markStopped(worktreeID: "wt-1", scriptKey: "repo:dev.sh", at: epoch)

        #expect(store.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.stopped))
        #expect(store.record(worktreeID: "wt-2", scriptKey: "repo:dev.sh")?.status == .running)
    }

    @Test func purgingOneWorktreeLeavesTheOthers() {
        var store = RunRecordStore()
        store.begin(record(id: "run-a", worktreeID: "wt-1"))
        store.begin(record(id: "run-b", worktreeID: "wt-2"))

        store.purge(worktreeID: "wt-1")

        #expect(store.records(worktreeID: "wt-1").isEmpty)
        #expect(store.records(worktreeID: "wt-2").count == 1)
    }

    // MARK: - Endpoint ownership

    @Test func portOwnerIsMatchedByHostAndPort() {
        var store = RunRecordStore()
        store.begin(record(
            id: "run-a",
            worktreeID: "wt-1",
            branch: "feature",
            endpoint: URL(string: "http://localhost:3000")!
        ))
        store.markRunning(runID: "run-a", sessionID: "session-a")

        #expect(store.activeRunOwningPort(3000, host: nil)?.branch == "feature")
        #expect(store.activeRunOwningPort(3001, host: nil) == nil)
        // Same port number, different machine — not a collision.
        #expect(store.activeRunOwningPort(3000, host: "devbox") == nil)
        #expect(store.activeRunOwningPort(3000, host: nil, excludingRunID: "run-a") == nil)
    }

    @Test func finishedRunsNoLongerOwnTheirPort() {
        var store = RunRecordStore()
        store.begin(record(id: "run-a", endpoint: URL(string: "http://localhost:3000")!))
        store.markRunning(runID: "run-a", sessionID: "session-a")
        store.finish(runID: "run-a", outcome: .succeeded, at: epoch)

        #expect(store.activeRunOwningPort(3000, host: nil) == nil)
    }

    @Test func schemeDefaultPortsCountAsEndpointPorts() {
        #expect(URL(string: "http://localhost")?.runEndpointPort == 80)
        #expect(URL(string: "https://example.test")?.runEndpointPort == 443)
        #expect(URL(string: "http://localhost:8080")?.runEndpointPort == 8080)
        #expect(URL(string: "file:///tmp/x")?.runEndpointPort == nil)
    }
}
