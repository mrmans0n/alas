import Foundation
import IOSurface

/// AlasSimService's name is its bundle identifier.
enum SimServiceName {
    static let bundleIdentifier = "io.nlopez.alas.simservice"
}

/// Calls from Alas into AlasSimService, which owns the private simulator frameworks.
@objc protocol SimServiceProtocol {
    /// Streams `udid` to the connection's exported `SimFrameSink`. Replies nil
    /// once frames flow, or an error message.
    func startStream(udid: String, reply: @escaping @Sendable (String?) -> Void)
    func stopStream(udid: String)
    /// `phase` is `begin`, `move` or `end`. `x` and `y` run from 0 to 1 from
    /// the top left of the portrait screen.
    func touch(udid: String, phase: String, x: Double, y: Double)
    /// `usage` is a USB HID keyboard usage (page 0x07).
    func key(udid: String, usage: UInt32, down: Bool)
    /// A serve-sim button name, such as `home`.
    func button(udid: String, name: String)
    /// The accessibility tree of `udid` as serve-sim's JSON, or an error message.
    func describe(udid: String, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// The bundle ID of the app in front, or nil (the home screen).
    func frontmostApp(udid: String, reply: @escaping @Sendable (String?) -> Void)
    /// Turns the device to a UIDeviceOrientation. Replies nil, or why it didn't.
    func rotate(udid: String, orientation: UInt32, reply: @escaping @Sendable (String?) -> Void)
}

/// Calls from AlasSimService back into Alas.
@objc protocol SimFrameSink {
    /// A new frame: an IOSurface-backed `420v` buffer from the service's pool,
    /// laid out as the portrait panel, and the interface orientation it shows.
    func frame(udid: String, surface: IOSurface, orientation: String?)
}
