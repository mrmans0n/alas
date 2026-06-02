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
        ReleaseChecker(arch: arch, fetch: { _ in data })
    }

    @Test func reportsUpdateWhenRemoteNewer() async {
        let result = await checker(returning: json(tag: "v0.6.0"))
            .check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
        guard case let .updateAvailable(info) = result,
              case let .stable(stable) = info else {
            Issue.record("expected updateAvailable(.stable), got \(result)")
            return
        }
        #expect(stable.version == SemanticVersion(major: 0, minor: 6, patch: 0))
    }

    @Test func reportsUpToDateWhenEqual() async {
        let result = await checker(returning: json(tag: "v0.5.1"))
            .check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
        #expect(result == .upToDate)
    }

    @Test func reportsUpToDateWhenRemoteOlder() async {
        let result = await checker(returning: json(tag: "v0.4.0"))
            .check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
        #expect(result == .upToDate)
    }

    @Test func reportsFailedOnMalformedJSON() async {
        let result = await checker(returning: Data("not json".utf8))
            .check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }

    @Test func reportsFailedWhenFetchThrows() async {
        struct Boom: Error {}
        let checker = ReleaseChecker(arch: "arm64", fetch: { _ in throw Boom() })
        let result = await checker.check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
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
            .check(current: SemanticVersion(major: 0, minor: 5, patch: 1))
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }
}
