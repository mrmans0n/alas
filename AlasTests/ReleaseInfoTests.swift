import Foundation
import Testing
@testable import Alas

struct ReleaseInfoTests {
    private func decode(_ json: String) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private let sample = """
    {
      "tag_name": "v0.6.0",
      "body": "## Fixes\\n- thing",
      "html_url": "https://github.com/mrmans0n/alas/releases/tag/v0.6.0",
      "prerelease": false,
      "draft": false,
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

    @Test func mapsToReleaseInfoWithMatchingArchDMG() throws {
        let info = ReleaseInfo.make(from: try decode(sample), arch: "arm64")
        #expect(info?.version == SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(info?.releaseNotes == "## Fixes\n- thing")
        #expect(info?.dmgURL?.absoluteString == "https://example.com/arm64.dmg")
        #expect(info?.htmlURL.absoluteString == "https://github.com/mrmans0n/alas/releases/tag/v0.6.0")
    }

    @Test func mapsWithNilDMGWhenArchAssetMissing() throws {
        let info = ReleaseInfo.make(from: try decode(sample), arch: "riscv")
        #expect(info?.dmgURL == nil)
    }

    @Test func mapFailsWhenTagUnparseable() throws {
        let bad = """
        {"tag_name": "nightly", "body": null, "html_url": "https://x.test", "prerelease": false, "draft": false, "assets": []}
        """
        #expect(ReleaseInfo.make(from: try decode(bad), arch: "arm64") == nil)
    }

    @Test func handlesNullBody() throws {
        let noBody = """
        {"tag_name": "v0.6.0", "body": null, "html_url": "https://x.test", "prerelease": false, "draft": false, "assets": []}
        """
        let info = ReleaseInfo.make(from: try decode(noBody), arch: "arm64")
        #expect(info?.releaseNotes == "")
    }
}
