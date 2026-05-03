import Foundation
import Observation

@Observable
final class ThemeStore {
    private(set) var current: Theme

    init(initialId: String = "cool-slate") throws {
        self.current = try Theme.loadBundled(id: initialId)
    }

    func activate(id: String) throws {
        self.current = try Theme.loadBundled(id: id)
    }
}
