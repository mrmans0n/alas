import SwiftUI

extension AppState {
    /// Two-way binding into `AppConfig` that auto-saves on each write.
    func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: kp] },
            set: { self.config[keyPath: kp] = $0
            self.saveConfig() }
        )
    }
}
