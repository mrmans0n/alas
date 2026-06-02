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

    private let identity: BuildIdentity
    private let checker: ReleaseChecker
    private let installSource: InstallSource
    private let defaults: UserDefaults
    private let isEnabled: () -> Bool

    private let lastCheckedKey = "io.nlopez.alas.updates.lastCheckedAt"

    init(
        identity: BuildIdentity = BuildIdentity.current(),
        checker: ReleaseChecker = ReleaseChecker(),
        installSource: InstallSource = .detect(),
        defaults: UserDefaults = .standard,
        isEnabled: @escaping () -> Bool
    ) {
        self.identity = identity
        self.checker = checker
        self.installSource = installSource
        self.defaults = defaults
        self.isEnabled = isEnabled
    }

    /// Where this copy was installed — used by the sheet to tailor the action.
    var source: InstallSource { installSource }

    /// Which release track this build belongs to. Surfaced for the sheet so
    /// the nightly variant can force the direct action row.
    var track: ReleaseTrack { identity.track }

    /// Throttled, silent-on-no-update check intended for app launch.
    func checkOnLaunch() {
        let last = defaults.object(forKey: lastCheckedKey) as? Date
        guard UpdateThrottle.shouldCheck(enabled: isEnabled(), lastCheckedAt: last, now: Date()) else { return }
        Task { await runCheck(announceNoUpdate: false) }
    }

    /// User-initiated check from the menu. Always runs; gives feedback either way.
    func checkManually() {
        Task { await runCheck(announceNoUpdate: true) }
    }

    private func runCheck(announceNoUpdate: Bool) async {
        let result = await checker.check(identity: identity)
        switch result {
        case .updateAvailable(let info):
            // Stamp only on a successful fetch — a failed check must not consume
            // the throttle budget, or a transient network error on launch would
            // suppress auto-checks for a full interval.
            defaults.set(Date(), forKey: lastCheckedKey)
            presentedUpdate = info
        case .upToDate:
            defaults.set(Date(), forKey: lastCheckedKey)
            if announceNoUpdate {
                presentInfo(title: "You're up to date", message: upToDateMessage())
            }
        case .failed(let message):
            if announceNoUpdate { presentInfo(title: "Couldn't check for updates", message: message) }
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
