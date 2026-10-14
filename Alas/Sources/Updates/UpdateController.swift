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
        let last = defaults.object(forKey: lastCheckedKey) as? Date
        guard !Task.isCancelled,
              UpdateThrottle.shouldCheck(enabled: isEnabled(), lastCheckedAt: last, now: now()) else { return }
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
            // Only a successful fetch consumes the daily throttle.
            defaults.set(now(), forKey: lastCheckedKey)
            availableUpdate = info
            if announceCheckResult { presentedUpdate = info }
        case .upToDate:
            defaults.set(now(), forKey: lastCheckedKey)
            availableUpdate = nil
            if announceCheckResult {
                presentInfo(title: "You're up to date", message: upToDateMessage())
            }
        case .failed(let message):
            if announceCheckResult { presentInfo(title: "Couldn't check for updates", message: message) }
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
