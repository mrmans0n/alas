import Foundation
import AlasModel

/// When the system-wide Stop Computer Use shortcut is live.
public enum ComputerUseStopShortcut {
    /// The binding to register: nil when the action is unbound or no session drives an app,
    /// so the key combo stays free for other apps the rest of the time.
    public static func registration(binding: ShortcutBinding?, driverActive: Bool) -> ShortcutBinding? {
        driverActive ? binding : nil
    }

    /// `eventHotKeyExistsErr`: another app holds the combination.
    public static let takenStatus: Int32 = -9878

    /// Whether a registration that failed with `status` (nil when it never reached Carbon: no
    /// key code, no handler) is tried again: only a combination another app holds, which frees
    /// up when that app quits or lets it go, and only while an agent drives.
    public static func retries(status: Int32?, driverActive: Bool) -> Bool {
        driverActive && status == takenStatus
    }
}
