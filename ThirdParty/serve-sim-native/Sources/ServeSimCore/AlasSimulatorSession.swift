import CoreVideo
import Foundation

/// Alas's entry point into the vendored serve-sim code: one booted
/// simulator's screen and input. Not from upstream; sync.sh leaves it alone.
public final class AlasSimulatorSession: @unchecked Sendable {
    public enum TouchPhase: String, Sendable {
        case begin, move, end
    }

    private enum Input: Sendable {
        /// Point touch input at the panel capture shows.
        case selectScreen
        case touch(TouchPhase, x: Double, y: Double)
        case key(usage: UInt32, down: Bool)
        case button(String)
    }

    public let udid: String
    private let capture = FrameCapture()
    private let hid = HIDInjector()
    /// `HIDInjector` is an actor. Input goes through one stream so a touch's
    /// begin, moves and end reach it in the order they were sent, and a panel
    /// change lands between gestures rather than inside one.
    private let input: AsyncStream<Input>.Continuation
    private let inputEvents: AsyncStream<Input>
    private var unsubscribeScreenChanges: (@Sendable () async -> Void)?

    public init(udid: String) {
        self.udid = udid
        (inputEvents, input) = AsyncStream.makeStream(of: Input.self)
    }

    deinit {
        input.finish()
    }

    /// Starts capture, then input. `onFrame` runs on a capture queue with an
    /// IOSurface-backed `420v` copy of each new frame, taken from a pool.
    /// Input sent before this returns waits until input is ready.
    public func start(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        try await capture.start(deviceUDID: udid) { pixelBuffer, _, _, _ in
            onFrame(pixelBuffer)
        }
        try await hid.setup(deviceUDID: udid)
        // setup() targets the profile's sole panel, which a two-panel device
        // lacks: until a panel is selected its touches go nowhere.
        let input = self.input
        unsubscribeScreenChanges = await capture.subscribeScreenChanges { input.yield(.selectScreen) }
        input.yield(.selectScreen)
        Task { [capture, hid, udid, inputEvents] in
            for await event in inputEvents {
                switch event {
                case .selectScreen:
                    // Nil keeps the sole-panel fallback for ordinary devices.
                    await hid.setScreen(screenID: try? await capture.activeScreenID())
                case .touch(let phase, let x, let y):
                    await hid.sendTouch(type: phase.rawValue, x: x, y: y, screenWidth: 0, screenHeight: 0)
                case .key(let usage, let down):
                    await hid.sendKey(type: down ? "down" : "up", usage: usage)
                case .button(let name):
                    await Self.press(name, hid: hid, udid: udid)
                }
            }
        }
    }

    public func stop() async {
        input.finish()
        await unsubscribeScreenChanges?()
        await capture.stop()
    }

    /// `x` and `y` run from 0 to 1 across the portrait screen, from its top left.
    public func touch(_ phase: TouchPhase, x: Double, y: Double) {
        input.yield(.touch(phase, x: x, y: y))
    }

    /// `usage` is a USB HID keyboard usage (page 0x07).
    public func key(usage: UInt32, down: Bool) {
        input.yield(.key(usage: usage, down: down))
    }

    /// One of serve-sim's button names: `home`, `lock`, `siri`,
    /// `side_button`, `app_switcher`, `swipe_home`.
    public func button(_ name: String) {
        input.yield(.button(name))
    }

    // Consumer-page (12) usages, as DeviceKit chrome lists them for its buttons.
    private static let consumerPage: UInt32 = 12
    private static let menuUsage: UInt32 = 0x40
    private static let powerUsage: UInt32 = 0x30

    /// Hardware buttons go in as arbitrary HID on the consumer page: Xcode 26
    /// drops the button messages upstream's `sendButton` builds, and its Siri
    /// event restarts SpringBoard. Menu is Home on every device, twice opens
    /// the app switcher; held Sleep/Wake starts Siri.
    private static func press(_ name: String, hid: HIDInjector, udid: String) async {
        switch name {
        case "home":
            await hid.sendButtonHID(page: consumerPage, usage: menuUsage, phase: "press")
        case "app_switcher":
            await hid.sendButtonHID(page: consumerPage, usage: menuUsage, phase: "press")
            try? await Task.sleep(for: .milliseconds(150))
            await hid.sendButtonHID(page: consumerPage, usage: menuUsage, phase: "press")
        case "lock", "side_button":
            await hid.sendButtonHID(page: consumerPage, usage: powerUsage, phase: "press")
        case "siri":
            await hid.sendButtonHID(page: consumerPage, usage: powerUsage, phase: "down")
            try? await Task.sleep(for: .milliseconds(1500))
            await hid.sendButtonHID(page: consumerPage, usage: powerUsage, phase: "up")
        default:
            await hid.sendButton(button: name, deviceUDID: udid)
        }
    }

    /// The booted simulator's accessibility tree as serve-sim's JSON (an array
    /// whose first node is the application, frames in points). Blocks for up
    /// to a few seconds; works without a running capture.
    public static func describeUI(udid: String) throws -> Data {
        SimFrameworks.load()
        return try AccessibilityBridge.shared.describeUI(udid: udid)
    }

    /// The bundle ID of the app in front on a booted simulator, or nil when
    /// SpringBoard shows none (the home screen). Doesn't walk the UI.
    public static func frontmostApp(udid: String) -> String? {
        SimFrameworks.load()
        return (try? AccessibilityBridge.shared.frontmostApp(udid: udid))?["bundleId"] as? String
    }
}
