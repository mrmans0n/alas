import Foundation
import Testing
@testable import Alas

struct BuildIdentityTests {
    private func dict(
        track: String? = nil,
        sha: String? = nil,
        buildDate: String? = nil,
        version: String? = "0.5.1"
    ) -> [String: Any] {
        var d: [String: Any] = [:]
        if let track { d["AlasReleaseTrack"] = track }
        if let sha { d["AlasGitSHA"] = sha }
        if let buildDate { d["AlasBuildDate"] = buildDate }
        if let version { d["CFBundleShortVersionString"] = version }
        return d
    }

    @Test func defaultsToStableWhenTrackMissing() {
        let id = BuildIdentity(infoDictionary: dict())
        #expect(id.track == .stable)
    }

    @Test func parsesStableExplicitly() {
        let id = BuildIdentity(infoDictionary: dict(track: "stable"))
        #expect(id.track == .stable)
    }

    @Test func parsesNightly() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly"))
        #expect(id.track == .nightly)
    }

    @Test func unknownTrackFallsBackToStable() {
        let id = BuildIdentity(infoDictionary: dict(track: "weird"))
        #expect(id.track == .stable)
    }

    @Test func emptyGitSHAIsNil() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly", sha: ""))
        #expect(id.gitSHA == nil)
    }

    @Test func populatedGitSHA() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly", sha: "abc1234567890abcdef1234567890abcdef12345"))
        #expect(id.gitSHA == "abc1234567890abcdef1234567890abcdef12345")
    }

    @Test func emptyBuildDateIsNil() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly", buildDate: ""))
        #expect(id.buildDate == nil)
    }

    @Test func parsesISO8601BuildDate() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly", buildDate: "2026-06-02T10:21:00Z"))
        #expect(id.buildDate != nil)
        let formatter = ISO8601DateFormatter()
        #expect(id.buildDate == formatter.date(from: "2026-06-02T10:21:00Z"))
    }

    @Test func malformedBuildDateIsNil() {
        let id = BuildIdentity(infoDictionary: dict(track: "nightly", buildDate: "not-a-date"))
        #expect(id.buildDate == nil)
    }

    @Test func versionDefaultsToZeroWhenMissing() {
        let id = BuildIdentity(infoDictionary: dict(version: nil))
        #expect(id.version == SemanticVersion(major: 0, minor: 0, patch: 0))
    }

    @Test func parsesVersionFromCFBundleShortVersionString() {
        let id = BuildIdentity(infoDictionary: dict(version: "0.6.2"))
        #expect(id.version == SemanticVersion(major: 0, minor: 6, patch: 2))
    }
}
