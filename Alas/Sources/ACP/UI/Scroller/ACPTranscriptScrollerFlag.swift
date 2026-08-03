import Foundation

/// Runtime switch between the legacy SwiftUI transcript ScrollView and the
/// AppKit-backed scroller. Defaults on for dev builds, off for release,
/// overridable either way with:
///   defaults write io.nlopez.alas alas.transcript.appkitScroller -bool NO
/// or from Settings > Debug > Experiments.
enum ACPTranscriptScrollerFlag {
    static let defaultsKey = "alas.transcript.appkitScroller"

    /// Posted by `setOverride` after writing a new override. Open
    /// `ACPMessageList` instances observe this to re-evaluate `isEnabled`
    /// and rebuild their transcript subtree without requiring an app
    /// restart.
    static let overrideDidChangeNotification = Notification.Name(
        "io.nlopez.alas.ACPTranscriptScrollerFlag.overrideDidChange"
    )

    static var isEnabled: Bool {
        isEnabledWithDefaults(UserDefaults.standard)
    }

    /// Internal seam for testing: reads the override from the given UserDefaults instance.
    nonisolated static func readOverride(from defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: defaultsKey) as? Bool
    }

    /// Internal seam for testing: computes isEnabled given a UserDefaults instance.
    nonisolated static func isEnabledWithDefaults(_ defaults: UserDefaults) -> Bool {
        let override = readOverride(from: defaults)
        #if DEBUG
        return resolve(override: override, isDebugBuild: true)
        #else
        return resolve(override: override, isDebugBuild: false)
        #endif
    }

    nonisolated static func resolve(override: Bool?, isDebugBuild: Bool) -> Bool {
        override ?? isDebugBuild
    }

    /// Writes an explicit override (e.g. from the Debug settings toggle) and
    /// broadcasts `overrideDidChangeNotification` so any already-open
    /// transcripts can pick up the change. `isEnabled` itself is a plain
    /// UserDefaults read with no observation of its own, so without this
    /// notification a flipped toggle would only take effect after the
    /// transcript view happened to re-render for an unrelated reason.
    nonisolated static func setOverride(
        _ override: Bool,
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(override, forKey: defaultsKey)
        notificationCenter.post(name: overrideDidChangeNotification, object: nil)
    }
}
