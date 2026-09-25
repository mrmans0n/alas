import Foundation
import Testing
@testable import Alas

struct ScheduledAgentReportStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-agent-reports-\(UUID().uuidString).sqlite")
            .path
    }

    private func report(
        id: String = "target-run",
        occurrenceID: String = "occurrence",
        projectID: String = "project",
        cleanupRequested: Bool = true
    ) -> ScheduledAgentReport {
        ScheduledAgentReport(
            id: id,
            occurrenceID: occurrenceID,
            scheduleID: "schedule",
            scheduleName: "Nightly audit",
            projectID: projectID,
            projectName: "Alas",
            agentID: "claude",
            modelID: "sonnet",
            request: "Review the open issues and label clear duplicates.",
            startedAt: epoch,
            cleanupRequested: cleanupRequested
        )
    }

    private var completion: ScheduledAgentCompletion {
        ScheduledAgentCompletion(
            outcome: .succeeded,
            summary: "Reviewed 12 issues and labeled 3 duplicates.",
            checks: [.init(name: "Unit tests", result: "Passed")],
            links: [.init(label: "PR #418", url: "https://example.test/pull/418")]
        )
    }

    @Test func reportSurvivesReopenAndOnlyItsAttachedSessionCanCompleteIt() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report())
        try await store.associateWorktree(
            reportID: "target-run",
            worktreeID: "worktree-1",
            branch: "scheduled/audit",
            baseCommit: "base-sha"
        )
        try await store.associateSession(reportID: "target-run", sessionID: "session-1")

        await #expect(throws: ScheduledAgentReportStoreError.sessionMismatch("target-run")) {
            try await store.finish(
                reportID: "target-run",
                authenticatedSessionID: "unrelated-session",
                completion: completion,
                at: epoch.addingTimeInterval(30)
            )
        }

        let finished = try await store.finish(
            reportID: "target-run",
            authenticatedSessionID: "session-1",
            completion: completion,
            at: epoch.addingTimeInterval(30)
        )
        #expect(finished.taskState == .succeeded)
        #expect(finished.worktreeID == "worktree-1")
        #expect(finished.completion == completion)

        let reopened = try ScheduledAgentReportStore(path: path)
        #expect(try await reopened.report(id: "target-run") == finished)
        #expect(try await reopened.page(projectID: "project", offset: 0, limit: 10) == [finished])
    }

    @Test func acceptedCompletionStaysRunningUntilThePromptSettlesAndRejectsDuplicates() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report())
        try await store.associateSession(reportID: "target-run", sessionID: "session-1")
        try await store.recordCompletion(
            reportID: "target-run",
            authenticatedSessionID: "session-1",
            completion: completion
        )

        let pending = try #require(try await store.report(id: "target-run"))
        #expect(pending.taskState == .running)
        #expect(pending.hasPendingWork)
        #expect(pending.finishedAt == nil)
        #expect(pending.completion == completion)

        await #expect(throws: ScheduledAgentReportStoreError.completionAlreadyRecorded("target-run")) {
            try await store.recordCompletion(
                reportID: "target-run",
                authenticatedSessionID: "session-1",
                completion: completion
            )
        }
        await #expect(throws: ScheduledAgentReportStoreError.sessionMismatch("target-run")) {
            try await store.finishRecordedCompletion(
                reportID: "target-run",
                authenticatedSessionID: "another-session"
            )
        }

        let finished = try await store.finishRecordedCompletion(
            reportID: "target-run",
            authenticatedSessionID: "session-1",
            at: epoch.addingTimeInterval(30)
        )
        #expect(finished.taskState == .succeeded)
        #expect(finished.finishedAt == epoch.addingTimeInterval(30))
        await #expect(throws: ScheduledAgentReportStoreError.invalidTransition("target-run")) {
            try await store.recordCompletion(
                reportID: "target-run",
                authenticatedSessionID: "session-1",
                completion: completion
            )
        }
    }

    @Test func cleanupRequiresSuccessAndFollowsPendingToOneTerminalState() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report())
        try await store.associateSession(reportID: "target-run", sessionID: "session-1")
        let finished = try await store.finish(
            reportID: "target-run",
            authenticatedSessionID: "session-1",
            completion: completion
        )
        #expect(try await store.report(id: "target-run")?.hasPendingWork == true)
        #expect(finished.cleanupState == .pending)
        #expect(finished.hasPendingWork)
        let retained = try await store.updateCleanup(
            reportID: "target-run",
            state: .retained,
            reason: "The worktree contains local changes."
        )
        #expect(retained.cleanupState == .retained)
        #expect(!retained.hasPendingWork)
        #expect(retained.cleanupReason == "The worktree contains local changes.")

        await #expect(throws: ScheduledAgentReportStoreError.invalidTransition("target-run")) {
            try await store.updateCleanup(reportID: "target-run", state: .removed)
        }
    }

    @Test func cleanupFailurePreservesTaskSuccessAndPartialRemovalDetails() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report())
        try await store.associateSession(reportID: "target-run", sessionID: "session-1")
        _ = try await store.finish(
            reportID: "target-run",
            authenticatedSessionID: "session-1",
            completion: completion
        )

        let reason = "The worktree was removed, but the ACP session row could not be deleted."
        let failed = try await store.updateCleanup(
            reportID: "target-run",
            state: .failed,
            reason: reason
        )
        #expect(failed.taskState == .succeeded)
        #expect(failed.cleanupState == .failed)
        #expect(failed.cleanupReason == reason)

        let reopened = try ScheduledAgentReportStore(path: path)
        #expect(try await reopened.report(id: "target-run") == failed)
        await #expect(throws: ScheduledAgentReportStoreError.invalidTransition("target-run")) {
            try await reopened.updateCleanup(reportID: "target-run", state: .removed)
        }
    }

    @Test func restartRetainsCompletedAndAcceptedReportsWithoutStartingCleanup() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try ScheduledAgentReportStore(path: path, pid: Int64.max)
        try await first.create(report(id: "running"))
        try await first.create(report(id: "cleanup"))
        try await first.associateSession(reportID: "cleanup", sessionID: "session-2")
        _ = try await first.finish(
            reportID: "cleanup",
            authenticatedSessionID: "session-2",
            completion: completion
        )
        try await first.create(report(id: "accepted"))
        try await first.associateSession(reportID: "accepted", sessionID: "session-3")
        try await first.recordCompletion(
            reportID: "accepted",
            authenticatedSessionID: "session-3",
            completion: completion
        )

        let relaunched = try ScheduledAgentReportStore(path: path)
        #expect(try await relaunched.reconcileAfterRestart(at: epoch.addingTimeInterval(60)) == 3)
        let interrupted = try #require(try await relaunched.report(id: "running"))
        #expect(interrupted.taskState == .interrupted)
        #expect(interrupted.cleanupState == .retained)
        let retained = try #require(try await relaunched.report(id: "cleanup"))
        #expect(retained.taskState == .succeeded)
        #expect(retained.cleanupState == .retained)
        #expect(retained.cleanupReason?.contains("restarted") == true)
        let accepted = try #require(try await relaunched.report(id: "accepted"))
        #expect(accepted.taskState == .interrupted)
        #expect(accepted.completion == completion)
        #expect(accepted.cleanupState == .retained)
        #expect(try await relaunched.reconcileAfterRestart(at: epoch.addingTimeInterval(120)) == 0)
    }

    @Test func restartReconciliationLeavesReportsOwnedByAnotherLiveStoreAlone() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pid = Int64(ProcessInfo.processInfo.processIdentifier)
        let first = try ScheduledAgentReportStore(path: path, instanceID: "first-store", pid: pid)
        try await first.create(report(id: "running"))
        try await first.create(report(id: "cleanup"))
        try await first.associateSession(reportID: "cleanup", sessionID: "session-2")
        _ = try await first.finish(
            reportID: "cleanup",
            authenticatedSessionID: "session-2",
            completion: completion
        )

        let second = try ScheduledAgentReportStore(path: path, instanceID: "second-store", pid: pid)
        #expect(try await second.reconcileAfterRestart(at: epoch.addingTimeInterval(60)) == 0)
        let running = try #require(try await second.report(id: "running"))
        #expect(running.taskState == .running)
        let pendingCleanup = try #require(try await second.report(id: "cleanup"))
        #expect(pendingCleanup.taskState == .succeeded)
        #expect(pendingCleanup.cleanupState == .pending)
    }

    @Test func legacyRowsWithoutOwnerColumnsAreMigratedAndReconciledAsOrphans() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let legacyDatabase = try SQLiteDatabase(path: path)
        try legacyDatabase.exec("""
        CREATE TABLE scheduled_agent_reports (
            id TEXT PRIMARY KEY NOT NULL,
            occurrence_id TEXT NOT NULL,
            schedule_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            started_at REAL NOT NULL,
            session_id TEXT,
            task_state TEXT NOT NULL,
            cleanup_state TEXT NOT NULL,
            payload BLOB NOT NULL
        )
        """)
        let oldReport = report(id: "legacy")
        try legacyDatabase.exec("""
        INSERT INTO scheduled_agent_reports (
            id, occurrence_id, schedule_id, project_id, started_at,
            session_id, task_state, cleanup_state, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            oldReport.id, oldReport.occurrenceID, oldReport.scheduleID, oldReport.projectID,
            oldReport.startedAt.timeIntervalSince1970, oldReport.sessionID,
            oldReport.taskState.rawValue, oldReport.cleanupState.rawValue,
            try JSONEncoder().encode(oldReport),
        ])

        let migratedStore = try ScheduledAgentReportStore(path: path)
        #expect(try await migratedStore.reconcileAfterRestart(at: epoch.addingTimeInterval(60)) == 1)
        let recovered = try #require(try await migratedStore.report(id: "legacy"))
        #expect(recovered.taskState == .interrupted)
        #expect(recovered.cleanupState == .retained)
    }

    @Test func reportBodyHasABoundedSizeAndOnlyCompletedReportsAreDeletable() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report(id: "small", cleanupRequested: false))
        try await store.associateSession(reportID: "small", sessionID: "session-1")
        let oversized = ScheduledAgentCompletion(
            outcome: .succeeded,
            summary: String(repeating: "x", count: ScheduledAgentReportLimits.maximumTextBytes + 1),
            checks: [],
            links: []
        )
        await #expect(throws: ScheduledAgentReportStoreError.payloadTooLarge(oversized.summary.utf8.count)) {
            try await store.finish(
                reportID: "small",
                authenticatedSessionID: "session-1",
                completion: oversized
            )
        }
        #expect(try await store.report(id: "small")?.taskState == .running)
        await #expect(throws: ScheduledAgentReportStoreError.reportNotSettled("small")) {
            try await store.delete(id: "small")
        }
        try await store.finish(
            reportID: "small",
            authenticatedSessionID: "session-1",
            completion: ScheduledAgentCompletion(
                outcome: .succeeded,
                summary: "Finished",
                checks: [],
                links: []
            )
        )
        #expect(try await store.delete(id: "small"))
        #expect(try await store.report(id: "small") == nil)
    }

    @Test func reportsWithPendingCleanupCannotBeDeletedUntilRemovalSettles() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ScheduledAgentReportStore(path: path)
        try await store.create(report(id: "pending", cleanupRequested: true))
        try await store.associateSession(reportID: "pending", sessionID: "session-1")
        try await store.finish(
            reportID: "pending",
            authenticatedSessionID: "session-1",
            completion: ScheduledAgentCompletion(
                outcome: .succeeded,
                summary: "Finished",
                checks: [],
                links: []
            )
        )

        #expect(try await store.report(id: "pending")?.cleanupState == .pending)
        await #expect(throws: ScheduledAgentReportStoreError.reportNotSettled("pending")) {
            try await store.delete(id: "pending")
        }
        try await store.updateCleanup(reportID: "pending", state: .removed)
        #expect(try await store.delete(id: "pending"))
    }
}

@Suite
@MainActor
struct ScheduledAgentRunRegistrationTests {
    private func registration() -> ScheduledAgentRunRegistration {
        ScheduledAgentRunRegistration(
            reportID: "report",
            occurrenceID: "occurrence",
            scheduleID: "schedule",
            projectID: "project",
            worktreeID: "worktree",
            sessionID: "session",
            promptID: UUID()
        )
    }

    private var completion: ScheduledAgentCompletion {
        ScheduledAgentCompletion(outcome: .succeeded, summary: "Complete.", checks: [], links: [])
    }

    @Test func oneSubmissionCanBePersistedAndLateSubmissionsAreClosed() {
        let active = registration()
        #expect(active.reserveCompletion())
        #expect(!active.acceptsCompletion)
        #expect(!active.reserveCompletion())

        active.retryAfterPersistenceFailure()
        #expect(active.acceptsCompletion)
        #expect(active.reserveCompletion())
        #expect(active.recordPersistedCompletion(completion))
        #expect(active.completion == completion)
        #expect(!active.reserveCompletion())

        active.invalidate()
        #expect(!active.acceptsCompletion)

        let late = registration()
        #expect(late.reserveCompletion())
        late.invalidate()
        #expect(!late.recordPersistedCompletion(completion))
        #expect(!late.reserveCompletion())
    }
}

@Suite(.serialized)
@MainActor
struct ScheduledAgentReportIntegrationTests {
    private actor SettlementGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private func git(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await Process.git(args, cwd: cwd, usesRemoteHostRegistry: false)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
        return result
    }

    @Test func completionWaitsForTheACPThreadAndCleanupRetainsDirtyWorktrees() async throws {
        try await exerciseCleanup(dirty: false)
        try await exerciseCleanup(dirty: true)
    }

    private func exerciseCleanup(dirty: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-report-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let worktreePath = root.appendingPathComponent("scheduled-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "main"], cwd: repository)
        _ = try await git(["config", "user.name", "Alas Tests"], cwd: repository)
        _ = try await git(["config", "user.email", "tests@example.invalid"], cwd: repository)
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        _ = try await git(["add", "README.md"], cwd: repository)
        _ = try await git(["commit", "-m", "base"], cwd: repository)
        let base = try await git(["rev-parse", "HEAD"], cwd: repository).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = "scheduled/report"
        _ = try await git(
            ["worktree", "add", "-b", branch, worktreePath.path, base],
            cwd: repository
        )
        _ = try await git(
            ["update-ref", "refs/remotes/origin/\(branch)", base],
            cwd: repository
        )

        let reportID = UUID().uuidString
        let sessionID = UUID().uuidString
        let occurrenceID = UUID().uuidString
        let projectID = "project"
        let worktree = Worktree(
            id: worktreePath.path,
            projectId: projectID,
            name: "scheduled",
            branch: branch,
            path: worktreePath,
            isMainWorktree: false,
            status: .clean,
            lastActivity: Date()
        )
        let reportPath = root.appendingPathComponent("reports.sqlite").path
        let sessionPath = root.appendingPathComponent("sessions.sqlite").path
        let reports = try ScheduledAgentReportStore(path: reportPath)
        try await reports.create(ScheduledAgentReport(
            id: reportID,
            occurrenceID: occurrenceID,
            scheduleID: "schedule",
            scheduleName: "Nightly report",
            projectID: projectID,
            projectName: "Integration fixture",
            branch: nil,
            baseCommit: nil,
            worktreeID: nil,
            sessionID: nil,
            agentID: "codex",
            modelID: nil,
            request: "Inspect the repository and report the result.",
            startedAt: Date(),
            cleanupRequested: true
        ))
        let manager = ACPSessionManager(
            worktreeId: worktree.id,
            worktreePath: worktreePath.path,
            store: try ACPSessionStore(path: sessionPath)
        )
        let session = manager.createSession(id: sessionID, agentId: "codex", autoRunDefault: false)
        let promptID = UUID()
        session.queue = [QueuedPrompt(id: promptID, blocks: [.text("Inspect the repository.")])]
        session.mcpAttachmentSummary = MCPAttachmentSummary(
            statuses: [.init(
                id: BuiltInAlasMCP.statusId,
                name: "Alas",
                transport: .stdio,
                disposition: .requested
            )],
            configurationFingerprint: "integration"
        )
        session.builtInMCPRegistration = .registered
        await manager.flushPersistence()
        try await reports.associateWorktree(
            reportID: reportID,
            worktreeID: worktree.id,
            branch: branch,
            baseCommit: base
        )
        try await reports.associateSession(reportID: reportID, sessionID: sessionID)
        let origin = ACPOrchestrationSessionOrigin(
            sessionId: sessionID,
            projectId: projectID,
            worktreeId: worktree.id
        )
        let completion = ScheduledAgentCompletion(
            outcome: .succeeded,
            summary: "Repository review complete.",
            checks: [.init(name: "Git safety", result: "Passed")],
            links: []
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in worktree.id },
            resolveACPSessionOrigin: { $0 == sessionID ? origin : nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            completeScheduledTask: { caller, submitted in
                guard caller == origin else {
                    return .error("No active scheduled ACP run accepts this completion.")
                }
                do {
                    try await reports.recordCompletion(
                        reportID: reportID,
                        authenticatedSessionID: caller.sessionId,
                        completion: submitted
                    )
                    return .text(["Completion recorded."])
                } catch {
                    return .error(error.localizedDescription)
                }
            },
            activateApp: {}
        )
        let response = await router.handle(.init(
            version: 1,
            sessionId: sessionID,
            cwd: "/unrelated/worktree",
            command: .scheduleComplete(completion)
        ))
        #expect(response == .text(["Completion recorded."]))
        #expect(try await reports.report(id: reportID)?.taskState == .running)

        let deadline = SettlementGate()
        let settlement = Task {
            await manager.waitForScheduledPrompt(
                for: sessionID,
                promptID: promptID,
                timeout: .seconds(10),
                deadlineWaiter: { _ in await deadline.enterAndWait() }
            )
        }
        session.queue[0].status = .sending
        await deadline.waitUntilEntered()
        session.queue.removeAll()
        session.transcript.streamingState = .sending
        await Task.yield()
        session.transcript.streamingState = .idle
        let settlementResult = await settlement.value
        await deadline.release()
        guard case .settled = settlementResult else {
            Issue.record("Expected the scheduled ACP prompt to settle before cleanup.")
            return
        }

        let finished = try await reports.finishRecordedCompletion(
            reportID: reportID,
            authenticatedSessionID: sessionID
        )
        #expect(finished.taskState == .succeeded)
        #expect(finished.cleanupState == .pending)

        if dirty {
            try Data("keep me\n".utf8).write(to: worktreePath.appendingPathComponent("local.txt"))
        }
        let worktrees = WorktreeService()
        let preflight = try await worktrees.deletePreflight(
            worktreePath: worktreePath,
            usesRemoteHostRegistry: false
        )
        let historyIsSafe = try await WorktreeService.scheduledCleanupHistoryIsSafe(
            baseCommit: base,
            expectedBranch: branch,
            worktreePath: worktreePath
        )
        let sessionPersistence = ACPSessionPersistence(path: sessionPath)
        if dirty {
            #expect(historyIsSafe)
            #expect(preflight.reasons.contains(.dirty))
            let retained = try await reports.updateCleanup(
                reportID: reportID,
                state: .retained,
                reason: "The worktree contains uncommitted changes."
            )
            #expect(retained.taskState == .succeeded)
            #expect(retained.cleanupState == .retained)
            #expect(FileManager.default.fileExists(atPath: worktreePath.path))
            #expect(try await sessionPersistence.loadSession(id: sessionID) != nil)
        } else {
            #expect(historyIsSafe)
            #expect(preflight.reasons.isEmpty)
            try await worktrees.remove(
                repoPath: repository,
                worktree: worktree,
                deleteBranchIfMerged: false,
                force: false,
                usesRemoteHostRegistry: false
            )
            try await sessionPersistence.deleteSession(id: sessionID)
            let removed = try await reports.updateCleanup(reportID: reportID, state: .removed)
            #expect(removed.taskState == .succeeded)
            #expect(removed.cleanupState == .removed)
            #expect(!FileManager.default.fileExists(atPath: worktreePath.path))
            #expect(try await sessionPersistence.loadSession(id: sessionID) == nil)
        }

        let reopened = try ScheduledAgentReportStore(path: reportPath)
        let durableReport = try #require(try await reopened.report(id: reportID))
        #expect(durableReport.taskState == .succeeded)
        #expect(durableReport.cleanupState == (dirty ? .retained : .removed))
    }
}

