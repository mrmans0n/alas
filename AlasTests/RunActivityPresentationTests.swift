import Foundation
import Testing
@testable import Alas

struct RunActivityPresentationTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func record(
        _ name: String,
        _ status: RunStatus,
        started: TimeInterval = -60,
        finished: TimeInterval? = nil
    ) -> RunRecord {
        RunRecord(
            id: "run-\(name)",
            scriptKey: "repo:\(name).sh",
            scriptName: name,
            worktreeID: "wt",
            branch: "main",
            target: RunExecutionTarget(host: nil, workingDirectory: "/wt"),
            status: status,
            startedAt: now.addingTimeInterval(started),
            finishedAt: finished.map { now.addingTimeInterval($0) }
        )
    }

    private static func failure(_ name: String, completed: TimeInterval = -30) -> RunScriptFailure {
        RunScriptFailure(
            id: "failure-\(name)",
            runID: "run-\(name)",
            scriptKey: "repo:\(name).sh",
            scriptName: name,
            worktreeID: "wt",
            branch: "main",
            exitCode: 1,
            completedAt: now.addingTimeInterval(completed)
        )
    }

    struct PillCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let input: RunActivityInput
        let pill: RunActivityPresentation.Pill
        let flagsFailure: Bool
    }

    static let pillCases: [PillCase] = [
        PillCase(
            testDescription: "one active run wins over a failure and flags it",
            input: RunActivityInput(records: [record("dev", .running)], failures: [failure("build")]),
            pill: .running(scriptKey: "repo:dev.sh", name: "dev", startedAt: now.addingTimeInterval(-60)),
            flagsFailure: true
        ),
        PillCase(
            testDescription: "several active runs collapse to a count",
            input: RunActivityInput(records: [record("dev", .running), record("web", .starting, started: -1)]),
            pill: .runningMany(count: 2),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a single starting run",
            input: RunActivityInput(records: [record("web", .starting, started: -1)]),
            pill: .starting(scriptKey: "repo:web.sh", name: "web"),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "an undismissed failure wins over a recent success",
            input: RunActivityInput(
                records: [record("test", .finished(.succeeded), finished: -1)],
                failures: [failure("build")]
            ),
            pill: .failed(failureID: "failure-build", runID: "run-build", name: "build", exitCode: 1),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a recent success",
            input: RunActivityInput(records: [record("test", .finished(.succeeded), finished: -1)]),
            pill: .succeeded(name: "test", duration: 59),
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a later stop hides an earlier success",
            input: RunActivityInput(records: [
                record("test", .finished(.succeeded), finished: -2),
                record("lint", .finished(.stopped), finished: -1),
            ]),
            pill: .none,
            flagsFailure: false
        ),
        PillCase(
            testDescription: "a lost observation shows nothing",
            input: RunActivityInput(records: [record("lint", .finished(.unknown), finished: -1)]),
            pill: .none,
            flagsFailure: false
        ),
    ]

    @Test(arguments: pillCases)
    func pillFollowsPrecedence(_ testCase: PillCase) {
        let presentation = RunActivityPresentation.make(input: testCase.input, now: Self.now)
        #expect(presentation.pill == testCase.pill)
        #expect(presentation.hasUndismissedFailure == testCase.flagsFailure)
    }

    @Test func successLingersForFourSeconds() {
        let justInside = RunActivityPresentation.make(
            input: RunActivityInput(records: [Self.record("test", .finished(.succeeded), finished: -3.5)]),
            now: Self.now
        )
        #expect(justInside.pill == .succeeded(name: "test", duration: 56.5))
        #expect(justInside.expiresAt == Self.now.addingTimeInterval(0.5))

        let expired = RunActivityPresentation.make(
            input: RunActivityInput(records: [Self.record("test", .finished(.succeeded), finished: -4)]),
            now: Self.now
        )
        #expect(expired.pill == .none)
        #expect(expired.expiresAt == nil)
    }

    @Test func aRecentSuccessOffersItsReportOnlyWhenOneExists() {
        func rows(reports: Set<String>) -> [[RunActivityPresentation.RowAction]] {
            RunActivityPresentation.make(
                input: RunActivityInput(
                    records: [Self.record("test", .finished(.succeeded), finished: -1)],
                    reportRunIDs: reports
                ),
                now: Self.now
            ).rows.map(\.actions)
        }
        #expect(rows(reports: ["run-test"]) == [[.report, .rerun]])
        #expect(rows(reports: []) == [[.rerun]])
    }

    @Test func rowsListActiveRunsBeforeFailuresAndOfferOutputOnlyForLiveTerminals() {
        let presentation = RunActivityPresentation.make(
            input: RunActivityInput(
                records: [Self.record("dev", .running, started: -120), Self.record("lint", .running, started: -5)],
                failures: [Self.failure("build", completed: -50), Self.failure("test", completed: -10)],
                liveTerminalKeys: ["repo:dev.sh"]
            ),
            now: Self.now
        )
        #expect(presentation.rows.map(\.name) == ["lint", "dev", "test", "build"])
        #expect(presentation.rows.map(\.actions) == [
            [.restart, .stop],
            [.output, .restart, .stop],
            [.report, .rerun],
            [.report, .rerun],
        ])
    }
}
