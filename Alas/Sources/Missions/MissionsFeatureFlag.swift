import Combine
import Foundation

enum MissionsFeatureFlag {
    static let defaultsKey = "alas.features.missions"
    static let didChangeNotification = Notification.Name(
        "alas.missions-feature-flag-did-change"
    )

    static var isEnabled: Bool { isEnabled(in: .standard) }

    nonisolated static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func updates(
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> AnyPublisher<Bool, Never> {
        notificationCenter.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .map { _ in isEnabled(in: defaults) }
            .eraseToAnyPublisher()
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        guard isEnabled(in: defaults) != enabled else { return }
        defaults.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
