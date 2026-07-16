import Testing
@testable import Alas

struct AlasCLIReviewTargetResolverTests {
    @Test func parsesBareNumber() {
        #expect(AlasCLIReviewTargetResolver.parse("123") == .number(123))
    }

    @Test func rejectsNonPositiveBareNumbers() {
        #expect(AlasCLIReviewTargetResolver.parse("0") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("-1") == nil)
    }

    @Test func rejectsNonPositiveURLNumbers() {
        #expect(AlasCLIReviewTargetResolver.parse("https://github.com/mrmans0n/alas/pull/0") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("https://gitlab.com/group/project/-/merge_requests/-1") == nil)
    }

    @Test func parsesGitHubPullURL() {
        let parsed = AlasCLIReviewTargetResolver.parse("https://github.com/mrmans0n/alas/pull/580")
        #expect(parsed == .url(host: "github.com", repositorySlug: "mrmans0n/alas", number: 580))
    }

    @Test func parsesGitLabMergeRequestURL() {
        let parsed = AlasCLIReviewTargetResolver.parse("https://gitlab.com/group/project/-/merge_requests/42")
        #expect(parsed == .url(host: "gitlab.com", repositorySlug: "group/project", number: 42))
    }

    @Test func rejectsUnsupportedURL() {
        #expect(AlasCLIReviewTargetResolver.parse("https://example.com/review/1") == nil)
    }

    @Test func rejectsMalformedProviderURL() {
        #expect(AlasCLIReviewTargetResolver.parse("https://github.com/mrmans0n/pull/580") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("https://gitlab.com/group/project/-/merge_requests/not-a-number") == nil)
    }

    @Test func parsesTwoDotRange() {
        #expect(AlasCLIReviewTargetResolver.parse("main..HEAD")
            == .range(base: "main", head: "HEAD", threeDot: false))
        #expect(AlasCLIReviewTargetResolver.parse("abc123..def456")
            == .range(base: "abc123", head: "def456", threeDot: false))
    }

    @Test func parsesThreeDotRange() {
        #expect(AlasCLIReviewTargetResolver.parse("main...HEAD")
            == .range(base: "main", head: "HEAD", threeDot: true))
    }

    @Test func rejectsRangesWithEmptySides() {
        #expect(AlasCLIReviewTargetResolver.parse("..HEAD") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("main..") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("...") == nil)
    }

    @Test func fallsBackToRevisionForBareRefs() {
        #expect(AlasCLIReviewTargetResolver.parse("abc1234") == .revision("abc1234"))
        #expect(AlasCLIReviewTargetResolver.parse("feature/login") == .revision("feature/login"))
        #expect(AlasCLIReviewTargetResolver.parse("HEAD~3") == .revision("HEAD~3"))
    }

    @Test func rejectsWhitespaceAndEmptyRevisions() {
        #expect(AlasCLIReviewTargetResolver.parse("two words") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("   ") == nil)
    }

    @Test func urlLikeStringsNeverBecomeRevisions() {
        // Unsupported/malformed provider URLs must stay hard errors, not
        // get rev-parsed as ref names.
        #expect(AlasCLIReviewTargetResolver.parse("https://example.com/review/1") == nil)
        #expect(AlasCLIReviewTargetResolver.parse("https://github.com/mrmans0n/pull/580") == nil)
    }
}
