import Foundation
import Testing
@testable import Alas

// UpdateController owns main-actor presentation state.
@MainActor
struct UpdateControllerTests {
    @Test func automaticMonitoringChecksAgainAfterADayWithoutPresentingASheet() async throws {
        let source = ReleaseSource()
        let domain = "UpdateControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let start = Date(timeIntervalSince1970: 1_000)
        var now = start
        var enabled = true
        var wake = 0
        let controller = UpdateController(
            identity: identity, checker: ReleaseChecker(fetch: { try await source.fetch($0) }),
            installSource: .direct, defaults: defaults, now: { now }, isEnabled: { enabled }
        )

        await controller.monitorAutomatically {
            wake += 1
            switch wake {
            case 1: now = start.addingTimeInterval(UpdateThrottle.interval - 1)
            case 2: now = start.addingTimeInterval(UpdateThrottle.interval)
            default: enabled = false
            }
        }

        #expect(await source.checkCount == 2)
        #expect(controller.availableUpdate?.id == "stable-2.0.0")
        #expect(controller.presentedUpdate == nil)
        now = now.addingTimeInterval(UpdateThrottle.interval)
        await controller.checkAutomatically()
        #expect(await source.checkCount == 2)
    }

    @Test func failedAutomaticCheckPreservesTheUpdateUntilASuccessfulCheckClearsIt() async throws {
        let source = ReleaseSource()
        let domain = "UpdateControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = UpdateController(
            identity: identity, checker: ReleaseChecker(fetch: { try await source.fetch($0) }),
            installSource: .direct, defaults: defaults, now: { now }, isEnabled: { true }
        )
        await controller.checkAutomatically()
        let detected = try #require(controller.availableUpdate)
        let checkedAt = defaults.object(forKey: lastCheckedKey) as? Date
        now = now.addingTimeInterval(UpdateThrottle.interval)
        await source.setResponse(version: nil)
        await controller.checkAutomatically()
        #expect(controller.availableUpdate == detected)
        #expect(defaults.object(forKey: lastCheckedKey) as? Date == checkedAt)

        await source.setResponse(version: "1.0.0")
        await controller.checkAutomatically()
        #expect(await source.checkCount == 3)
        #expect(controller.availableUpdate == nil)
        #expect(controller.presentedUpdate == nil)
        #expect(defaults.object(forKey: lastCheckedKey) as? Date == now)
        let relaunched = UpdateController(
            identity: identity, checker: ReleaseChecker(fetch: { try await source.fetch($0) }),
            installSource: .direct, defaults: defaults, isEnabled: { true }
        )
        #expect(relaunched.availableUpdate == nil)
    }

    @Test func manualCheckJoinsTheAutomaticFetchAndBypassesTheDailyThrottle() async throws {
        let source = ReleaseSource(holdFirstCheck: true)
        let domain = "UpdateControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = UpdateController(
            identity: identity, checker: ReleaseChecker(fetch: { try await source.fetch($0) }),
            installSource: .direct, defaults: defaults, isEnabled: { true }
        )
        let automatic = Task { await controller.checkAutomatically() }
        var starts = source.starts.makeAsyncIterator()
        _ = await starts.next()
        // This task cannot release the fetch until the main actor yields to the manual check.
        Task { await source.releaseFetch() }
        await controller.checkManually()
        await automatic.value
        #expect(await source.checkCount == 1)
        #expect(controller.presentedUpdate?.id == "stable-2.0.0")

        controller.presentedUpdate = nil
        await controller.checkManually()
        #expect(await source.checkCount == 2)
        #expect(controller.presentedUpdate == controller.availableUpdate)
    }

    @Test(arguments: [
        BuildIdentity(track: .stable, version: SemanticVersion(major: 1, minor: 0, patch: 0)),
        BuildIdentity(track: .stable, version: SemanticVersion(major: 2, minor: 0, patch: 0)),
        BuildIdentity(track: .nightly, version: SemanticVersion(major: 1, minor: 0, patch: 0), gitSHA: "installed-sha"),
        BuildIdentity(track: .nightly, version: SemanticVersion(major: 1, minor: 0, patch: 0), gitSHA: "release-sha"),
    ])
    func detectedUpdateSurvivesOnlyCompatibleThrottledRelaunches(relaunchedBuild: BuildIdentity) async throws {
        let source = ReleaseSource()
        let domain = "UpdateControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let installedBuild = BuildIdentity(
            track: relaunchedBuild.track, version: identity.version,
            gitSHA: relaunchedBuild.track == .nightly ? "installed-sha" : nil
        )
        let checker = ReleaseChecker(fetch: { try await source.fetch($0) })
        let original = UpdateController(
            identity: installedBuild, checker: checker, installSource: .direct,
            defaults: defaults, isEnabled: { true }
        )
        await original.checkAutomatically()
        let detected = try #require(original.availableUpdate)
        let relaunched = UpdateController(
            identity: relaunchedBuild, checker: checker, installSource: .direct,
            defaults: try #require(UserDefaults(suiteName: domain)), isEnabled: { true }
        )
        await relaunched.checkAutomatically()

        #expect(relaunched.availableUpdate == (installedBuild == relaunchedBuild ? detected : nil))
        #expect(relaunched.presentedUpdate == nil)
        #expect(await source.checkCount == 1)
    }

    private var identity: BuildIdentity {
        BuildIdentity(track: .stable, version: SemanticVersion(major: 1, minor: 0, patch: 0))
    }
    private var lastCheckedKey: String { "io.nlopez.alas.updates.lastCheckedAt" }

    private actor ReleaseSource {
        let starts: AsyncStream<Void>
        private let started: AsyncStream<Void>.Continuation
        private let holdFirstCheck: Bool
        private var pendingFetch: CheckedContinuation<Void, Never>?
        private var version: String? = "2.0.0"
        private(set) var checkCount = 0

        init(holdFirstCheck: Bool = false) {
            let stream = AsyncStream<Void>.makeStream()
            starts = stream.stream
            started = stream.continuation
            self.holdFirstCheck = holdFirstCheck
        }

        func fetch(_ url: URL) async throws -> Data {
            if url.lastPathComponent == "CHANGELOG.md" { return Data() }
            if url.path.contains("/git/ref/tags/nightly") {
                return Data(#"{"object":{"sha":"release-sha","type":"commit"}}"#.utf8)
            }
            checkCount += 1
            if holdFirstCheck && checkCount == 1 {
                await withCheckedContinuation {
                    pendingFetch = $0
                    started.yield(())
                }
            }
            guard let version else { throw URLError(.notConnectedToInternet) }
            return Data("""
            {"tag_name":"v\(version)","body":"Release notes",
             "html_url":"https://example.com/releases/v\(version)","prerelease":false,
             "draft":false,"target_commitish":"main","published_at":"2026-10-14T00:00:00Z","assets":[]}
            """.utf8)
        }

        func setResponse(version: String?) { self.version = version }
        func releaseFetch() {
            pendingFetch?.resume()
            pendingFetch = nil
        }
    }
}
