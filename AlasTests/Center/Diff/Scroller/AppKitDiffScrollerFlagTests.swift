import Foundation
import Testing
@testable import Alas

@Suite("AppKitDiffScrollerFlag")
struct AppKitDiffScrollerFlagTests {
    @Test("explicit overrides win and build defaults differ")
    func resolution() {
        #expect(AppKitDiffScrollerFlag.resolve(override: true, isDebugBuild: false))
        #expect(!AppKitDiffScrollerFlag.resolve(override: false, isDebugBuild: true))
        #expect(AppKitDiffScrollerFlag.resolve(override: nil, isDebugBuild: true))
        #expect(!AppKitDiffScrollerFlag.resolve(override: nil, isDebugBuild: false))
    }

    @Test("setOverride persists and broadcasts")
    func persistenceAndNotification() async {
        let suite = "AppKitDiffScrollerFlagTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        await confirmation { received in
            let token = center.addObserver(
                forName: AppKitDiffScrollerFlag.overrideDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in received() }
            defer { center.removeObserver(token) }
            AppKitDiffScrollerFlag.setOverride(true, in: defaults, notificationCenter: center)
        }
        #expect(AppKitDiffScrollerFlag.readOverride(from: defaults) == true)
    }
}
