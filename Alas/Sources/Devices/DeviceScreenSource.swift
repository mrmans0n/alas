import AlasCore
import Foundation

/// What a device screen view streams frames from and sends input to: a
/// simulator through AlasSimService, or an Android device through scrcpy.
@MainActor
protocol DeviceScreenSource: AnyObject {
    func subscribe(
        udid: String,
        onFrame: @escaping @MainActor (DeviceFrame) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID
    func unsubscribe(udid: String, token: UUID)
    func touch(udid: String, phase: String, point: DeviceScreenPoint)
    func key(udid: String, usage: UInt32, down: Bool)
    /// A scroll over `point`, in wheel steps.
    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double)
    /// A held key repeated on the Mac.
    func keyRepeat(udid: String, usage: UInt32)
    /// Whether `scroll` reaches the device, so a recorded flow keeps it.
    var takesScroll: Bool { get }
}

extension DeviceScreenSource {
    /// Simulators take scrolls as drags; they ignore the wheel.
    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double) {}

    var takesScroll: Bool { false }

    /// Simulators repeat a held key themselves.
    func keyRepeat(udid: String, usage: UInt32) {}
}

extension SimulatorStreamClient: DeviceScreenSource {}
