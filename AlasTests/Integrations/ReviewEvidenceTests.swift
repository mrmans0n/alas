import Foundation
import Testing
@testable import Alas

struct ReviewEvidenceTests {
    @Test func logDetailTruncatesDeterministically() {
        let item = ReviewEvidenceItem(
            id: "ci:test",
            section: .ci,
            title: "test",
            subtitle: "CI",
            status: .failed,
            providerURL: URL(string: "https://github.com/mrmans0n/alas/actions/runs/1/job/2")
        )

        let detail = ReviewEvidenceDetail.truncated(
            item: item,
            body: String(repeating: "x", count: 12_000),
            filePath: nil,
            line: nil,
            maxLength: 4_000
        )

        #expect(detail.body.count == 4_000)
        #expect(detail.body.hasSuffix("\n\n[Log truncated by Alas.]"))
        #expect(detail.isTruncated)
    }

    @Test func contextIncludesProviderURLAndLocation() {
        let item = ReviewEvidenceItem(
            id: "feedback:thread-1",
            section: .feedback,
            title: "reviewer",
            subtitle: "Please simplify this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1")
        )
        let detail = ReviewEvidenceDetail(
            item: item,
            body: "Please simplify this branch lookup.",
            filePath: "Alas/Sources/Right/RightPaneState.swift",
            line: 240,
            isTruncated: false
        )

        let context = ReviewEvidenceContextFormatter.format(detail)

        #expect(context.contains("Section: Feedback"))
        #expect(context.contains("Title: reviewer"))
        #expect(context.contains("URL: https://github.com/mrmans0n/alas/pull/42#discussion_r1"))
        #expect(context.contains("Location: Alas/Sources/Right/RightPaneState.swift:240"))
        #expect(context.contains("Please simplify this branch lookup."))
    }
}
