import Foundation
import Testing
@testable import Alas

struct ReleaseCheckerTests {
    private func json(tag: String) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "body": "notes",
          "html_url": "https://github.com/mrmans0n/alas/releases/tag/\(tag)",
          "prerelease": false,
          "draft": false,
          "target_commitish": "abc1234567890abcdef1234567890abcdef12345",
          "published_at": "2026-06-02T10:21:00Z",
          "assets": [
            {"name": "Alas-\(tag.replacingOccurrences(of: "v", with: ""))-arm64.dmg",
             "browser_download_url": "https://example.com/\(tag)-arm64.dmg"}
          ]
        }
        """.utf8)
    }

    private func checker(returning data: Data, arch: String = "arm64") -> ReleaseChecker {
        ReleaseChecker(
            stableReleaseURL: URL(string: "https://stable.test")!,
            nightlyReleaseURL: URL(string: "https://nightly.test")!,
            arch: arch,
            fetch: { _ in data }
        )
    }

    private func stableIdentity(version: SemanticVersion) -> BuildIdentity {
        BuildIdentity(track: .stable, version: version)
    }

    @Test func reportsUpdateWhenRemoteNewer() async {
        let result = await checker(returning: json(tag: "v0.6.0"))
            .check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        guard case let .updateAvailable(info) = result else {
            Issue.record("expected updateAvailable, got \(result)")
            return
        }
        guard case let .stable(stable) = info else {
            Issue.record("expected .stable, got \(info)")
            return
        }
        #expect(stable.version == SemanticVersion(major: 0, minor: 6, patch: 0))
    }

    @Test func reportsUpToDateWhenEqual() async {
        let result = await checker(returning: json(tag: "v0.5.1"))
            .check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        #expect(result == .upToDate)
    }

    @Test(arguments: ["\n", "\r\n"])
    func includesSkippedVersionsFromTargetTagNewestFirst(lineEnding: String) async {
        let changelog = """
        # Changelog
        ## [Unreleased]
        future work
        ## [0.7.0] - 2026-06-05
        newer release
        ## [0.6.0] - 2026-06-04
        duplicate latest notes
        ## [0.5.2] - 2026-06-02
        ### Fixes
        - older fix
        ## [Invalid]
        invalid section
        ## [0.5.9-beta]
        prerelease notes
        ## [0.5.8]
        ## [0.5.10] - 2026-06-03
        ### Features
        - newer feature
        ## [0.5.2] - 2026-06-02
        duplicate older fix
        ## [0.5.1] - 2026-06-01
        already installed
        ## [0.5.0] - 2026-05-30
        old release
        """
        let checker = ReleaseChecker(fetch: { url in
            if url == URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/latest")! {
                return self.json(tag: "v0.6.0")
            }
            #expect(url.absoluteString == "https://raw.githubusercontent.com/mrmans0n/alas/v0.6.0/CHANGELOG.md")
            return Data(changelog.replacingOccurrences(of: "\n", with: lineEnding).utf8)
        })
        let result = await checker.check(identity: stableIdentity(version: SemanticVersion(parsing: "0.5.1")!))
        guard case let .updateAvailable(.stable(info)) = result else {
            Issue.record("expected stable update, got \(result)")
            return
        }
        #expect(info.releaseNotes == """
        ## [0.6.0] - 2026-06-04

        notes

        ## [0.5.10] - 2026-06-03

        ### Features
        - newer feature

        ## [0.5.2] - 2026-06-02

        ### Fixes
        - older fix
        """)
    }

    @Test(arguments: [nil, "not a changelog", "## [Unreleased]\nfuture work", "## [0.6.0]\nlatest only", "## [0.5.2]\nmissing target release"])
    func preservesLatestNotesWhenHistoryIsUnavailable(changelog: String?) async {
        let checker = ReleaseChecker(fetch: { url in
            if url == URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/latest")! {
                return self.json(tag: "v0.6.0")
            }
            guard let changelog else { throw URLError(.timedOut) }
            return Data(changelog.utf8)
        })
        let result = await checker.check(identity: stableIdentity(version: SemanticVersion(parsing: "0.5.1")!))
        guard case let .updateAvailable(.stable(info)) = result else {
            Issue.record("expected stable update, got \(result)")
            return
        }
        #expect(info.releaseNotes == "notes")
    }

    @Test func reportsUpToDateWhenRemoteOlder() async {
        let result = await checker(returning: json(tag: "v0.4.0"))
            .check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        #expect(result == .upToDate)
    }

    @Test func reportsFailedOnMalformedJSON() async {
        let result = await checker(returning: Data("not json".utf8))
            .check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }

    @Test func reportsFailedWhenFetchThrows() async {
        struct Boom: Error {}
        let checker = ReleaseChecker(
            stableReleaseURL: URL(string: "https://stable.test")!,
            nightlyReleaseURL: URL(string: "https://nightly.test")!,
            arch: "arm64",
            fetch: { _ in throw Boom() }
        )
        let result = await checker.check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }

    @Test func reportsFailedWhenTagUnparseable() async {
        let data = Data("""
        {"tag_name":"nightly","body":null,"html_url":"https://x.test","prerelease":false,"draft":false,"target_commitish":"abc1234","published_at":"2026-06-02T10:21:00Z","assets":[]}
        """.utf8)
        let result = await checker(returning: data)
            .check(identity: stableIdentity(version: SemanticVersion(major: 0, minor: 5, patch: 1)))
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }

    // MARK: - Nightly track

    private static let stableTestURL = URL(string: "https://stable.test")!
    private static let nightlyTestURL = URL(string: "https://nightly.test")!
    private static let tagRefTestURL = URL(string: "https://tagref.test")!

    private func nightlyReleaseJSON(publishedAt: String) -> Data {
        // `target_commitish` is intentionally a branch name to mirror what
        // GitHub returns for the rolling nightly release in production.
        Data("""
        {
          "tag_name": "nightly",
          "body": "nightly notes",
          "html_url": "https://github.com/mrmans0n/alas/releases/tag/nightly",
          "prerelease": true,
          "draft": false,
          "target_commitish": "main",
          "published_at": "\(publishedAt)",
          "assets": [
            {"name": "Alas-nightly.dmg", "browser_download_url": "https://example.com/nightly.dmg"}
          ]
        }
        """.utf8)
    }

    private func nightlyTagRefJSON(sha: String) -> Data {
        Data("""
        {"ref":"refs/tags/nightly","node_id":"x","url":"https://example.test","object":{"sha":"\(sha)","type":"commit","url":"https://example.test/obj"}}
        """.utf8)
    }

    private func nightlyChecker(tagSHA: String, publishedAt: String) -> ReleaseChecker {
        ReleaseChecker(
            stableReleaseURL: Self.stableTestURL,
            nightlyReleaseURL: Self.nightlyTestURL,
            nightlyTagRefURL: Self.tagRefTestURL,
            arch: "arm64",
            fetch: { url in
                if url == Self.tagRefTestURL {
                    return self.nightlyTagRefJSON(sha: tagSHA)
                }
                return self.nightlyReleaseJSON(publishedAt: publishedAt)
            }
        )
    }

    private func iso(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    private func nightlyIdentity(sha: String?, buildDate: String?) -> BuildIdentity {
        BuildIdentity(
            track: .nightly,
            version: SemanticVersion(major: 0, minor: 5, patch: 1),
            gitSHA: sha,
            buildDate: buildDate.map { iso($0) }
        )
    }

    @Test func nightlyReportsUpdateWhenSHADiffersAndRemoteNewer() async {
        let checker = nightlyChecker(tagSHA: "fff9999", publishedAt: "2026-06-02T12:00:00Z")
        let result = await checker.check(identity: nightlyIdentity(
            sha: "aaa1111aaa1111aaa1111aaa1111aaa1111aaa11",
            buildDate: "2026-06-02T10:00:00Z"
        ))
        guard case let .updateAvailable(.nightly(info)) = result else {
            Issue.record("expected .updateAvailable(.nightly), got \(result)")
            return
        }
        #expect(info.shortSHA == "fff9999")
    }

    @Test func nightlyReportsUpToDateWhenSHAMatches() async {
        let sameSHA = "abc1234567890abcdef1234567890abcdef12345"
        let checker = nightlyChecker(tagSHA: sameSHA, publishedAt: "2026-06-02T12:00:00Z")
        let result = await checker.check(identity: nightlyIdentity(
            sha: sameSHA,
            buildDate: "2026-06-02T10:00:00Z"
        ))
        #expect(result == .upToDate)
    }

    @Test func nightlyReportsUpdateEvenWhenReleasePublishedAtIsOld() async {
        // The rolling nightly release's `published_at` reflects the original
        // creation time, not the latest update, so it must not gate the SHA
        // comparison. A different tag SHA always means a new build.
        let checker = nightlyChecker(tagSHA: "fff9999", publishedAt: "2020-01-01T00:00:00Z")
        let result = await checker.check(identity: nightlyIdentity(
            sha: "aaa1111aaa1111aaa1111aaa1111aaa1111aaa11",
            buildDate: "2026-06-02T10:00:00Z"
        ))
        guard case .updateAvailable = result else {
            Issue.record("expected .updateAvailable, got \(result)")
            return
        }
    }

    @Test func nightlyReportsUpToDateWhenLocalSHAMissing() async {
        // Hand-built nightlies (no stamped SHA) can't be compared. Don't
        // pester with updates we can't verify.
        let checker = nightlyChecker(tagSHA: "fff9999", publishedAt: "2026-06-02T12:00:00Z")
        let result = await checker.check(identity: nightlyIdentity(
            sha: nil,
            buildDate: "2026-06-02T10:00:00Z"
        ))
        #expect(result == .upToDate)
    }

    @Test func nightlyUsesTagRefSHANotTargetCommitish() async {
        // Even though the release payload's `target_commitish` says "main",
        // the checker must use the SHA returned by the tag-ref endpoint.
        let checker = nightlyChecker(tagSHA: "deadbeef0000000000000000000000000000beef", publishedAt: "2026-06-02T12:00:00Z")
        let result = await checker.check(identity: nightlyIdentity(
            sha: "aaa1111aaa1111aaa1111aaa1111aaa1111aaa11",
            buildDate: "2026-06-02T10:00:00Z"
        ))
        guard case let .updateAvailable(.nightly(info)) = result else {
            Issue.record("expected .updateAvailable(.nightly), got \(result)")
            return
        }
        #expect(info.shortSHA == "deadbee")
        #expect(info.fullSHA == "deadbeef0000000000000000000000000000beef")
    }

    @Test func stableViaIdentityStillReportsUpdate() async {
        let checker = ReleaseChecker(
            stableReleaseURL: Self.stableTestURL,
            nightlyReleaseURL: Self.nightlyTestURL,
            nightlyTagRefURL: Self.tagRefTestURL,
            arch: "arm64",
            fetch: { _ in self.json(tag: "v0.6.0") }
        )
        let result = await checker.check(identity: stableIdentity(
            version: SemanticVersion(major: 0, minor: 5, patch: 1)
        ))
        guard case let .updateAvailable(.stable(stable)) = result else {
            Issue.record("expected .updateAvailable(.stable), got \(result)")
            return
        }
        #expect(stable.version == SemanticVersion(major: 0, minor: 6, patch: 0))
    }

    @Test func nightlyHitsBothReleaseAndTagRefURLs() async {
        let recorder = FetchedURLRecorder()
        let checker = ReleaseChecker(
            stableReleaseURL: Self.stableTestURL,
            nightlyReleaseURL: Self.nightlyTestURL,
            nightlyTagRefURL: Self.tagRefTestURL,
            arch: "arm64",
            fetch: { url in
                await recorder.record(url)
                if url == Self.tagRefTestURL {
                    return self.nightlyTagRefJSON(sha: "fff9999")
                }
                return self.nightlyReleaseJSON(publishedAt: "2026-06-02T12:00:00Z")
            }
        )
        _ = await checker.check(identity: nightlyIdentity(sha: "aaa", buildDate: "2026-06-02T10:00:00Z"))
        let observed = await recorder.urls
        #expect(observed.contains(Self.nightlyTestURL))
        #expect(observed.contains(Self.tagRefTestURL))
        #expect(!observed.contains(Self.stableTestURL))
    }
}

/// `ReleaseChecker.Fetch` is `@Sendable`, so the probe cannot append to a
/// captured local `var`. This records the requested URLs instead.
private actor FetchedURLRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
