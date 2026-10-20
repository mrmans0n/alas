import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@Suite("Shepherd record retention")
struct ShepherdRecordRetentionTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    static let cases: [(phase: ShepherdPhase, finishedDaysAgo: Double?, updatedDaysAgo: Double, kept: Bool)] = [
        (.merged, 8, 8, false),
        (.closed, 6, 6, true),
        // Finished without a finishedAt: counted from updatedAt.
        (.merged, nil, 8, false),
        (.watching, nil, 30, true),
        (.escalated(.noProgress), nil, 30, true),
    ]

    @Test("finished records are dropped after seven days and active ones never are", arguments: cases)
    func prune(phase: ShepherdPhase, finishedDaysAgo: Double?, updatedDaysAgo: Double, kept: Bool) {
        var record = ShepherdRecord(
            id: ShepherdRecordID(
                worktreeID: "/tmp/wt",
                providerKind: .github,
                host: "github.com",
                repositorySlug: "o/r",
                requestNumber: 7
            ),
            sessionID: "session",
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "o",
                repository: "r",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/o/r")!
            ),
            branch: "feature",
            baseBranch: "main",
            autoFix: true,
            autoMerge: false,
            now: Self.now.addingTimeInterval(-40 * Self.day)
        )
        record.phase = phase
        record.finishedAt = finishedDaysAgo.map { Self.now.addingTimeInterval(-$0 * Self.day) }
        record.updatedAt = Self.now.addingTimeInterval(-updatedDaysAgo * Self.day)

        #expect(ShepherdRecordRetention.prune([record], now: Self.now).count == (kept ? 1 : 0))
    }
}
