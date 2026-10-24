import Foundation
import AlasModel

/// When the system-wide Stop Computer Use shortcut is live.
public enum ComputerUseStopShortcut {
    /// The binding to register: nil when the action is unbound or no session drives an app,
    /// so the key combo stays free for other apps the rest of the time.
    public static func registration(binding: ShortcutBinding?, driverActive: Bool) -> ShortcutBinding? {
        driverActive ? binding : nil
    }
}
