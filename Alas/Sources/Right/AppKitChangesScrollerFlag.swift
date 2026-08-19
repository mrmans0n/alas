import Foundation

enum AppKitChangesScrollerFlag {
    static let defaultsKey = "alas.changes.appKitScroller"
    static let overrideDidChangeNotification = Notification.Name(
        "io.nlopez.alas.AppKitChangesScrollerFlag.overrideDidChange"
    )

    static var isEnabled: Bool {
        isEnabledWithDefaults(.standard)
    }

    nonisolated static func readOverride(from defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: defaultsKey) as? Bool
    }

    nonisolated static func isEnabledWithDefaults(_ defaults: UserDefaults) -> Bool {
        #if DEBUG
        resolve(override: readOverride(from: defaults), isDebugBuild: true)
        #else
        resolve(override: readOverride(from: defaults), isDebugBuild: false)
        #endif
    }

    nonisolated static func resolve(override: Bool?, isDebugBuild: Bool) -> Bool {
        override ?? isDebugBuild
    }

    nonisolated static func setOverride(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(enabled, forKey: defaultsKey)
        notificationCenter.post(name: overrideDidChangeNotification, object: nil)
    }
}
