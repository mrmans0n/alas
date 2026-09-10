import Foundation
import Testing
@testable import Alas

struct RunTabPresentationTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func script(
        cwd: String? = nil,
        endpoint: URL? = nil
    ) -> RunScript {
        RunScript(
            scope: .repo,
            fileName: "dev.sh",
            fileURL: URL(fileURLWithPath: "/wt/.alas/scripts/dev.sh"),
            displayName: "Dev Server",
            onExit: .keep,
            cwd: cwd,
            isExecutable: true,
            endpoint: endpoint
        )
    }

    private func record(
        status: RunStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        failureID: String? = nil,
        endpoint: URL? = nil,
        portConflict: RunPortConflict? = nil,
        host: String? = nil
    ) -> RunRecord {
        RunRecord(
            id: "run-1",
            scriptKey: "repo:dev.sh",
            scriptName: "Dev Server",
            worktreeID: "wt-1",
            branch: "main",
            target: RunExecutionTarget(host: host, workingDirectory: "/wt"),
            endpoint: endpoint,
            status: status,
            startedAt: startedAt ?? epoch,
            finishedAt: finishedAt,
            failureID: failureID,
            portConflict: portConflict
        )
    }

    private func row(
        script: RunScript? = nil,
        record: RunRecord? = nil,
        hasTerminal: Bool = false,
        hasCapturedOutput: Bool = false,
        host: String? = nil,
        workingDirectory: String = "/wt",
        now: Date? = nil
    ) -> RunRowPresentation {
        RunTabPresentation.row(
            RunRowInput(
                script: script ?? self.script(),
                record: record,
                hasTerminal: hasTerminal,
                hasCapturedOutput: hasCapturedOutput,
                target: RunExecutionTarget(host: host, workingDirectory: workingDirectory)
            ),
            now: now ?? epoch
        )
    }

    // MARK: - States

    @Test func neverRunScriptOffersRunOnly() {
        let row = row()
        #expect(row.statusLabel == "Not run")
        #expect(row.tone == .idle)
        #expect(row.detail == nil)
        #expect(row.actions == [.start(label: "Run"), .edit])
    }

    @Test func runningScriptOffersStopAndRestart() {
        let row = row(
            record: record(status: .running),
            hasTerminal: true,
            now: epoch.addingTimeInterval(180)
        )
        #expect(row.statusLabel == "Running")
        #expect(row.tone == .active)
        #expect(row.isActive)
        #expect(row.detail == "Started 3m ago")
        #expect(row.actions == [.stop, .restart, .openTerminal, .edit])
    }

    @Test func runningScriptWithEndpointOffersOpen() {
        let endpoint = URL(string: "http://localhost:3000")!
        let row = row(
            script: script(endpoint: endpoint),
            record: record(status: .running, endpoint: endpoint)
        )
        #expect(row.actions.contains(.openEndpoint(endpoint)))
    }

    /// Mid-launch there is nothing serving yet, so the endpoint link would
    /// only produce a connection refused.
    @Test func startingScriptDoesNotOfferItsEndpointYet() {
        let endpoint = URL(string: "http://localhost:3000")!
        let row = row(
            script: script(endpoint: endpoint),
            record: record(status: .starting, endpoint: endpoint)
        )
        #expect(row.statusLabel == "Starting")
        #expect(row.detail == "Launching terminal")
        #expect(!row.actions.contains(.openEndpoint(endpoint)))
    }

    @Test func failedRunReportsExitCodeDurationAndOutputLink() {
        let row = row(
            record: record(
                status: .finished(.failed(exitCode: 42)),
                finishedAt: epoch.addingTimeInterval(75),
                failureID: "failure-1"),
            hasCapturedOutput: true,
            now: epoch.addingTimeInterval(75 + 3_600)
        )
        #expect(row.statusLabel == "Failed")
        #expect(row.tone == .failure)
        #expect(row.detail == "exit 42 · 1m 15s · 1h ago")
        #expect(row.actions == [.start(label: "Rerun"), .showOutput(failureID: "failure-1"), .edit])
    }

    @Test func failedRunWithoutRetainedOutputDoesNotOfferDeadOutputAction() {
        let row = row(record: record(status: .finished(.failed(exitCode: 42)), failureID: "gone"))
        #expect(row.actions == [.start(label: "Rerun"), .edit])
    }

    @Test func succeededRunReportsDurationWithoutClaimingVerification() {
        let row = row(
            record: record(status: .finished(.succeeded), finishedAt: epoch.addingTimeInterval(9)),
            now: epoch.addingTimeInterval(9)
        )
        #expect(row.statusLabel == "Succeeded")
        #expect(row.tone == .success)
        #expect(row.detail == "9s · just now")
        #expect(row.actions == [.start(label: "Rerun"), .edit])
    }

    @Test func stoppedRunSaysSoInsteadOfFailing() {
        let row = row(
            record: record(status: .finished(.stopped), finishedAt: epoch.addingTimeInterval(30)),
            now: epoch.addingTimeInterval(30)
        )
        #expect(row.statusLabel == "Stopped")
        #expect(row.tone == .warning)
        #expect(row.detail == "stopped before it finished · 30s · just now")
    }

    @Test func interruptedRunIsNeverPresentedAsSuccess() {
        let row = row(
            record: record(status: .finished(.unknown), finishedAt: epoch.addingTimeInterval(30)),
            now: epoch.addingTimeInterval(30)
        )
        #expect(row.statusLabel == "Unknown")
        #expect(row.tone == .warning)
        #expect(row.detail == "no exit status observed · 30s · just now")
        #expect(!row.actions.contains(.openEndpoint(URL(string: "http://localhost:3000")!)))
    }

    // MARK: - Terminal lifetime

    /// An open shell is not evidence a command is running: it only decides
    /// whether "jump to terminal" has a destination.
    @Test func liveTerminalDoesNotMakeAFinishedRunLookActive() {
        let row = row(record: record(status: .finished(.succeeded), finishedAt: epoch), hasTerminal: true)
        #expect(!row.isActive)
        #expect(row.statusLabel == "Succeeded")
        #expect(row.actions == [.start(label: "Rerun"), .openTerminal, .edit])
    }

    // MARK: - Execution host

    @Test func localWorktreeRootShowsNoExtraLocationChip() {
        let row = row(workingDirectory: "/wt")
        #expect(row.locationLabel == nil)
        #expect(row.locationDetail == "This Mac · /wt")
    }

    @Test func localSubdirectoryShowsTheRelativeWorkingDirectory() {
        let row = row(script: script(cwd: "apps/web"), workingDirectory: "/wt/apps/web")
        #expect(row.locationLabel == "apps/web")
        #expect(row.locationDetail == "This Mac · /wt/apps/web")
    }

    @Test func remoteTargetShowsHostAndWorkingDirectory() {
        let row = row(
            script: script(cwd: "apps/web"),
            host: "devbox",
            workingDirectory: "/srv/wt/apps/web"
        )
        #expect(row.locationLabel == "devbox · apps/web")
        #expect(row.locationDetail == "devbox · /srv/wt/apps/web")
    }

    // MARK: - Port conflicts

    @Test func portConflictNamesTheOtherOwnerWithoutOfferingToKillIt() {
        let row = row(record: record(
            status: .running,
            portConflict: .ownedByRun(worktreeID: "wt-2", branch: "feature", scriptName: "Web")
        ))
        #expect(row.conflictLabel == "Port already served by Web on feature")
        // Reporting a collision must not turn into an offer to kill anything
        // but our own run.
        #expect(row.actions == [.stop, .restart, .edit])
    }

    @Test func externalPortConflictIsReportedGenerically() {
        let row = row(record: record(status: .running, portConflict: .externalProcess))
        #expect(row.conflictLabel == "Port already in use by another process")
    }

    // MARK: - Formatting

    @Test func durationsFormatByMagnitude() {
        #expect(RunTabPresentation.format(duration: 0.2) == "0s")
        #expect(RunTabPresentation.format(duration: 45) == "45s")
        #expect(RunTabPresentation.format(duration: 90) == "1m 30s")
        #expect(RunTabPresentation.format(duration: 3_780) == "1h 3m")
    }

    @Test func relativeTimesFormatByMagnitude() {
        #expect(RunTabPresentation.relative(from: epoch, to: epoch) == "just now")
        #expect(RunTabPresentation.relative(from: epoch, to: epoch.addingTimeInterval(59)) == "just now")
        #expect(RunTabPresentation.relative(from: epoch, to: epoch.addingTimeInterval(600)) == "10m ago")
        #expect(RunTabPresentation.relative(from: epoch, to: epoch.addingTimeInterval(7_200)) == "2h ago")
        #expect(RunTabPresentation.relative(from: epoch, to: epoch.addingTimeInterval(3 * 86_400)) == "3d ago")
    }
}
