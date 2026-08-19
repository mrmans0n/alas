import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct AppKitChangesScrollerFlagTests {
    @Test func explicitOverrideWinsBuildDefault() {
        #expect(AppKitChangesScrollerFlag.resolve(override: true, isDebugBuild: false))
        #expect(!AppKitChangesScrollerFlag.resolve(override: false, isDebugBuild: true))
    }

    @Test func missingOverrideUsesBuildDefault() {
        #expect(AppKitChangesScrollerFlag.resolve(override: nil, isDebugBuild: true))
        #expect(!AppKitChangesScrollerFlag.resolve(override: nil, isDebugBuild: false))
    }

    @Test func settingOverridePersistsAndNotifies() throws {
        let suite = "AppKitChangesScrollerFlagTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let notifications = NotificationCenter()
        var received = false
        let observer = notifications.addObserver(
            forName: AppKitChangesScrollerFlag.overrideDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in received = true }
        defer {
            notifications.removeObserver(observer)
            defaults.removePersistentDomain(forName: suite)
        }

        AppKitChangesScrollerFlag.setOverride(
            true,
            in: defaults,
            notificationCenter: notifications
        )

        #expect(AppKitChangesScrollerFlag.readOverride(from: defaults) == true)
        #expect(received)
    }
}
