import Foundation
import Testing
@testable import Alas

struct DiffReviewRailThreadCountsTests {
    @Test func perPathCountExcludesResolvedAndOutdatedThreads() {
        let counts = DiffReviewRailThreadCounts(threads: [
            thread(id: "1", path: "A.swift"),
            thread(id: "2", path: "A.swift"),
            thread(id: "3", path: "A.swift", isResolved: true),
            thread(id: "4", path: "A.swift", isOutdated: true),
            thread(id: "5", path: "B.swift"),
        ])

        #expect(counts.openCount(forPath: "A.swift") == 2)
        #expect(counts.openCount(forPath: "B.swift") == 1)
        #expect(counts.openCount(forPath: "Missing.swift") == 0)
    }

    @Test func totalsMatchWholeThreadListSemantics() {
        let counts = DiffReviewRailThreadCounts(threads: [
            thread(id: "1", path: "A.swift"),
            thread(id: "2", path: nil),
            thread(id: "3", path: "B.swift", isResolved: true),
            thread(id: "4", path: "B.swift", isResolved: true, isOutdated: true),
            thread(id: "5", path: "C.swift", isOutdated: true),
        ])

        // Open excludes resolved and outdated; a nil-path thread still counts.
        #expect(counts.openTotal == 2)
        // Resolved counts resolved threads even when they are also outdated.
        #expect(counts.resolvedTotal == 2)
    }

    @Test func emptyThreadListHasNoCounts() {
        let counts = DiffReviewRailThreadCounts(threads: [])

        #expect(counts.openTotal == 0)
        #expect(counts.resolvedTotal == 0)
        #expect(counts.openCount(forPath: "A.swift") == 0)
    }

    private func thread(
        id: String,
        path: String?,
        isResolved: Bool = false,
        isOutdated: Bool = false
    ) -> ReviewThread {
        ReviewThread(
            id: id,
            path: path,
            line: 1,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: isResolved,
            isOutdated: isOutdated,
            isFileLevel: false,
            comments: [],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )
    }
}
