import AppKit
import Foundation
import Observation

/// Orchestrates update checks and drives presentation. The only stateful piece
/// of the Updates module. Pure logic lives in the injected collaborators.
@MainActor
@Observable
final class UpdateController {
    /// Non-nil when an update sheet should be presented.
    var presentedUpdate: ReleaseInfo?

    /// Last successfully detected update, independent of sheet presentation.
    private(set) var availableUpdate: ReleaseInfo?

    private let identity: BuildIdentity
    private let checker: ReleaseChecker
    private let installSource: InstallSource
    private let defaults: UserDefaults
    private let isEnabled: () -> Bool
    private let now: () -> Date
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var announceCheckResult = false

    private let lastCheckedKey = "io.nlopez.alas.updates.lastCheckedAt"
    private static let availableUpdateKey = "io.nlopez.alas.updates.availableUpdate"
    private static let lastAutomaticAttemptKey = "io.nlopez.alas.updates.lastAutomaticAttemptAt"

    init(
        identity: BuildIdentity = BuildIdentity.current(),
        checker: ReleaseChecker = ReleaseChecker(),
        installSource: InstallSource = .detect(),
        defaults: UserDefaults = AlasProfile.userDefaults,
        now: @escaping () -> Date = Date.init,
        isEnabled: @escaping () -> Bool
    ) {
        self.identity = identity
        self.checker = checker
        self.installSource = installSource
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
        availableUpdate = Self.restoreUpdate(defaults: defaults, identity: identity)
    }

    /// Where this copy was installed — used by the sheet to tailor the action.
    var source: InstallSource { installSource }

    /// Which release track this build belongs to. Surfaced for the sheet so
    /// the nightly variant can force the direct action row.
    var track: ReleaseTrack { identity.track }

    /// Owned by the root view's task, so disabling automatic checks stops the loop.
    func monitorAutomatically(
        waitForNextCheck: () async throws -> Void = {
            try await Task.sleep(for: .seconds(15 * 60))
        }
    ) async {
        while !Task.isCancelled && isEnabled() {
            await checkAutomatically()
            do {
                try await waitForNextCheck()
            } catch {
                return
            }
        }
    }

    func checkAutomatically() async {
        let lastChecked = defaults.object(forKey: lastCheckedKey) as? Date
        let lastAttempt = defaults.object(forKey: Self.lastAutomaticAttemptKey) as? Date
        let last: Date?
        if let lastChecked, let lastAttempt {
            last = max(lastChecked, lastAttempt)
        } else {
            last = lastChecked ?? lastAttempt
        }
        let date = now()
        guard !Task.isCancelled, checkTask == nil,
              UpdateThrottle.shouldCheck(enabled: isEnabled(), lastCheckedAt: last, now: date) else { return }
        defaults.set(date, forKey: Self.lastAutomaticAttemptKey)
        await runCheck(manually: false)
    }

    /// User-initiated checks bypass the throttle and join an existing fetch.
    func checkManually() async {
        await runCheck(manually: true)
    }

    func presentAvailableUpdate() {
        presentedUpdate = availableUpdate
    }

    private func runCheck(manually: Bool) async {
        announceCheckResult = announceCheckResult || manually
        if let checkTask {
            await checkTask.value
            return
        }
        let task = Task { await performCheck() }
        checkTask = task
        await task.value
    }

    private func performCheck() async {
        defer {
            checkTask = nil
            announceCheckResult = false
        }
        let result = await checker.check(identity: identity)
        switch result {
        case .updateAvailable(let info):
            persistUpdate(info)
            availableUpdate = info
            defaults.set(now(), forKey: lastCheckedKey)
            if announceCheckResult { presentedUpdate = info }
        case .upToDate:
            defaults.removeObject(forKey: Self.availableUpdateKey)
            availableUpdate = nil
            defaults.set(now(), forKey: lastCheckedKey)
            if announceCheckResult {
                presentInfo(title: "You're up to date", message: upToDateMessage())
            }
        case .failed(let message):
            if announceCheckResult { presentInfo(title: "Couldn't check for updates", message: message) }
        }
    }

    private func persistUpdate(_ info: ReleaseInfo) {
        var cached = [
            "installedVersion": identity.version.description,
            "track": identity.track.rawValue,
            "releaseNotes": info.releaseNotes,
            "htmlURL": info.htmlURL.absoluteString,
        ]
        cached["installedSHA"] = identity.gitSHA
        cached["dmgURL"] = info.dmgURL?.absoluteString
        switch info {
        case .stable(let release):
            cached["version"] = release.version.description
        case .nightly(let release):
            cached["sha"] = release.fullSHA
        }
        defaults.set(cached, forKey: Self.availableUpdateKey)
    }

    private static func restoreUpdate(defaults: UserDefaults, identity: BuildIdentity) -> ReleaseInfo? {
        guard let cached = defaults.dictionary(forKey: availableUpdateKey) as? [String: String],
              cached["installedVersion"] == identity.version.description,
              cached["track"] == identity.track.rawValue,
              cached["installedSHA"] == identity.gitSHA,
              let notes = cached["releaseNotes"],
              let htmlURL = cached["htmlURL"].flatMap(URL.init(string:)) else { return nil }
        let dmgURL = cached["dmgURL"].flatMap(URL.init(string:))
        switch identity.track {
        case .stable:
            guard let version = cached["version"].flatMap(SemanticVersion.init(parsing:)),
                  version > identity.version else { return nil }
            return .stable(StableReleaseInfo(version: version, releaseNotes: notes, htmlURL: htmlURL, dmgURL: dmgURL))
        case .nightly:
            guard let installedSHA = identity.gitSHA, let sha = cached["sha"],
                  !sha.isEmpty, sha != installedSHA else { return nil }
            return .nightly(NightlyReleaseInfo(
                shortSHA: String(sha.prefix(7)), fullSHA: sha,
                releaseNotes: notes, htmlURL: htmlURL, dmgURL: dmgURL
            ))
        }
    }

    private func upToDateMessage() -> String {
        switch identity.track {
        case .stable:
            return "Alas \(identity.version) is the latest version."
        case .nightly:
            if let sha = identity.gitSHA {
                return "Nightly \(sha.prefix(7)) is current."
            } else {
                return "This nightly build is current."
            }
        }
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
