import Combine
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct MissionsFeatureFlagTests {
    @Test func unsetDefaultsAreDisabled() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        #expect(!MissionsFeatureFlag.isEnabled(in: defaults))
    }

    @Test func explicitValuePersistsAndPostsOneNotification() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: MissionsFeatureFlag.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        MissionsFeatureFlag.setEnabled(true, in: defaults)

        #expect(MissionsFeatureFlag.isEnabled(in: defaults))
        #expect(notifications == 1)
    }

    @Test func settingSameValueIsIdempotent() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        MissionsFeatureFlag.setEnabled(false, in: defaults)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: MissionsFeatureFlag.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        MissionsFeatureFlag.setEnabled(false, in: defaults)
        #expect(notifications == 0)
    }

    @Test func directDefaultsWritesPublishUpdatedValue() async {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        await confirmation { updated in
            let subscription = MissionsFeatureFlag.updates(in: defaults).sink { isEnabled in
                #expect(isEnabled)
                updated()
            }

            defaults.set(true, forKey: MissionsFeatureFlag.defaultsKey)
            withExtendedLifetime(subscription) {}
        }
    }
}
