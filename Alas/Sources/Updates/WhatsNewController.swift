import Foundation
import Observation
import os

/// Decides when the "What's new" corner card is shown and remembers which
/// release the user has seen. The rules live in `WhatsNewPolicy`.
@MainActor
@Observable
final class WhatsNewController {
    /// Non-nil while the corner card should be visible.
    var presented: WhatsNewEntry?

    let catalog: WhatsNewCatalog

    private let identity: BuildIdentity
    private let defaults: UserDefaults
    private let hadUpdateCheck: Bool
    @ObservationIgnored private var didEvaluateLaunch = false

    private static let lastSeenKey = "io.nlopez.alas.whatsNew.lastSeenVersion"
    /// Written by `UpdateController` after a successful check; one signal of an install that predates this feature.
    private static let updatesLastCheckedKey = "io.nlopez.alas.updates.lastCheckedAt"
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "whats-new")

    init(
        identity: BuildIdentity = .current(),
        catalog: WhatsNewCatalog = .bundled(),
        defaults: UserDefaults = AlasProfile.userDefaults
    ) {
        self.identity = identity
        self.catalog = catalog
        self.defaults = defaults
        // UpdateController writes this key only after a network check, so reading it here is order-safe.
        hadUpdateCheck = defaults.object(forKey: Self.updatesLastCheckedKey) != nil
        for problem in catalog.problems {
            Self.logger.error(
                "Skipping what's new entry \(problem.file, privacy: .public): \(problem.message, privacy: .public)"
            )
        }
    }

    /// Whether Help > What's New has anything to show for this build.
    var hasLatest: Bool {
        WhatsNewPolicy.latestEntry(current: identity.version, entries: catalog.entries) != nil
    }

    /// Runs once per process; later calls are no-ops so a re-run root task cannot re-present.
    /// `hasConfiguredProjects` is durable evidence of an existing install for users whose
    /// update checks are disabled or have never succeeded.
    func evaluateOnLaunch(hasConfiguredProjects: Bool) {
        guard !didEvaluateLaunch else { return }
        didEvaluateLaunch = true
        let decision = WhatsNewPolicy.onLaunch(
            track: identity.track,
            current: identity.version,
            lastSeen: lastSeen,
            isExistingInstall: hadUpdateCheck || hasConfiguredProjects,
            entries: catalog.entries
        )
        if let version = decision.seenVersionToStore {
            defaults.set(version.description, forKey: Self.lastSeenKey)
        }
        if let entry = decision.entry {
            presented = entry
        }
    }

    /// Help > What's New. Works on any track and leaves the stored version alone.
    func showLatest() {
        guard let entry = WhatsNewPolicy.latestEntry(current: identity.version, entries: catalog.entries)
        else { return }
        presented = entry
    }

    /// Closes the card. On stable, records the current version as seen.
    func dismiss() {
        presented = nil
        guard identity.track == .stable else { return }
        let seen = WhatsNewPolicy.seenVersionAfterDismiss(current: identity.version, lastSeen: lastSeen)
        defaults.set(seen.description, forKey: Self.lastSeenKey)
    }

    private var lastSeen: SemanticVersion? {
        defaults.string(forKey: Self.lastSeenKey).flatMap(SemanticVersion.init(parsing:))
    }
}

extension WhatsNewCatalog {
    /// Entries bundled in the app's `WhatsNew` resource folder. A missing folder yields an empty catalog.
    static func bundled() -> WhatsNewCatalog {
        let directory = Bundle.main.url(forResource: "WhatsNew", withExtension: nil)
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("WhatsNew")
        return load(directory: directory)
    }
}
