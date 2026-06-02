import Foundation
import Testing
@testable import Alas

struct ReleaseInfoTests {
    private func decode(_ json: String) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private let sample = """
    {
      "tag_name": "v0.6.0",
      "body": "## Fixes\\n- thing",
      "html_url": "https://github.com/mrmans0n/alas/releases/tag/v0.6.0",
      "prerelease": false,
      "draft": false,
      "target_commitish": "abc1234567890abcdef1234567890abcdef12345",
      "published_at": "2026-06-02T10:21:00Z",
      "assets": [
        {"name": "Alas-0.6.0-arm64.dmg", "browser_download_url": "https://example.com/arm64.dmg"},
        {"name": "Alas-0.6.0-x86_64.dmg", "browser_download_url": "https://example.com/x86_64.dmg"}
      ]
    }
    """

    @Test func decodesGitHubReleaseSnakeCase() throws {
        let release = try decode(sample)
        #expect(release.tagName == "v0.6.0")
        #expect(release.assets.count == 2)
        #expect(release.assets.first?.browserDownloadUrl.absoluteString == "https://example.com/arm64.dmg")
    }

    @Test func makesStableReleaseInfoWithMatchingArchDMG() throws {
        let info = ReleaseInfo.makeStable(from: try decode(sample), arch: "arm64")
        guard case let .stable(stable) = info else {
            Issue.record("expected .stable, got \(String(describing: info))")
            return
        }
        #expect(stable.version == SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(stable.releaseNotes == "## Fixes\n- thing")
        #expect(stable.dmgURL?.absoluteString == "https://example.com/arm64.dmg")
        #expect(stable.htmlURL.absoluteString == "https://github.com/mrmans0n/alas/releases/tag/v0.6.0")
    }

    @Test func makesStableWithNilDMGWhenArchAssetMissing() throws {
        let info = ReleaseInfo.makeStable(from: try decode(sample), arch: "riscv")
        guard case let .stable(stable) = info else {
            Issue.record("expected .stable")
            return
        }
        #expect(stable.dmgURL == nil)
    }

    @Test func makeStableReturnsNilWhenTagUnparseable() throws {
        let bad = """
        {"tag_name": "nightly", "body": null, "html_url": "https://x.test", "prerelease": false, "draft": false, "target_commitish": "abc1234", "published_at": "2026-06-02T10:21:00Z", "assets": []}
        """
        #expect(ReleaseInfo.makeStable(from: try decode(bad), arch: "arm64") == nil)
    }

    @Test func stableHandlesNullBody() throws {
        let noBody = """
        {"tag_name": "v0.6.0", "body": null, "html_url": "https://x.test", "prerelease": false, "draft": false, "target_commitish": "abc1234", "published_at": "2026-06-02T10:21:00Z", "assets": []}
        """
        let info = ReleaseInfo.makeStable(from: try decode(noBody), arch: "arm64")
        guard case let .stable(stable) = info else {
            Issue.record("expected .stable")
            return
        }
        #expect(stable.releaseNotes == "")
    }

    @Test func decodesTargetCommitishAndPublishedAt() throws {
        let release = try decode(sample)
        #expect(release.targetCommitish == "abc1234567890abcdef1234567890abcdef12345")
        let formatter = ISO8601DateFormatter()
        #expect(release.publishedAt == formatter.date(from: "2026-06-02T10:21:00Z"))
    }

    @Test func makesNightlyReleaseInfoWithShortSHAAndAsset() throws {
        let json = """
        {
          "tag_name": "nightly",
          "body": "## Changes\\n- nightly bits",
          "html_url": "https://github.com/mrmans0n/alas/releases/tag/nightly",
          "prerelease": true,
          "draft": false,
          "target_commitish": "main",
          "published_at": "2026-06-02T10:21:00Z",
          "assets": [
            {"name": "Alas-nightly.dmg", "browser_download_url": "https://example.com/nightly.dmg"},
            {"name": "Alas-nightly.app.zip", "browser_download_url": "https://example.com/nightly.zip"}
          ]
        }
        """
        let info = ReleaseInfo.makeNightly(
            from: try decode(json),
            tagSHA: "abc1234567890abcdef1234567890abcdef12345"
        )
        guard case let .nightly(nightly) = info else {
            Issue.record("expected .nightly, got \(String(describing: info))")
            return
        }
        #expect(nightly.shortSHA == "abc1234")
        #expect(nightly.fullSHA == "abc1234567890abcdef1234567890abcdef12345")
        #expect(nightly.dmgURL?.absoluteString == "https://example.com/nightly.dmg")
        #expect(nightly.releaseNotes == "## Changes\n- nightly bits")
        let formatter = ISO8601DateFormatter()
        #expect(nightly.publishedAt == formatter.date(from: "2026-06-02T10:21:00Z"))
    }

    @Test func makeNightlyReturnsNilWhenTagSHAEmpty() throws {
        let json = """
        {"tag_name":"nightly","body":null,"html_url":"https://x.test","prerelease":true,"draft":false,"target_commitish":"main","published_at":"2026-06-02T10:21:00Z","assets":[]}
        """
        #expect(ReleaseInfo.makeNightly(from: try decode(json), tagSHA: "") == nil)
    }

    @Test func makeNightlyHasNilDMGWhenAssetMissing() throws {
        let json = """
        {"tag_name":"nightly","body":null,"html_url":"https://x.test","prerelease":true,"draft":false,"target_commitish":"main","published_at":"2026-06-02T10:21:00Z","assets":[]}
        """
        let info = ReleaseInfo.makeNightly(from: try decode(json), tagSHA: "abc1234")
        guard case let .nightly(nightly) = info else {
            Issue.record("expected .nightly")
            return
        }
        #expect(nightly.dmgURL == nil)
    }

    @Test func decodesGitRef() throws {
        let json = """
        {"ref":"refs/tags/nightly","node_id":"abc","url":"https://example.test","object":{"sha":"abc1234567890abcdef1234567890abcdef12345","type":"commit","url":"https://example.test/obj"}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let ref = try decoder.decode(GitRef.self, from: Data(json.utf8))
        #expect(ref.object.sha == "abc1234567890abcdef1234567890abcdef12345")
        #expect(ref.object.type == "commit")
    }
}
