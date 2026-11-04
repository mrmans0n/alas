import CoreVideo
import Foundation

/// Alas's entry point into the vendored serve-sim code: one booted
/// simulator's screen and input. Not from upstream; sync.sh leaves it alone.
public final class AlasSimulatorSession: @unchecked Sendable {
    public enum TouchPhase: String, Sendable {
        case begin, move, end
    }

    private enum Input: Sendable {
        case touch(TouchPhase, x: Double, y: Double)
        case key(usage: UInt32, down: Bool)
        case button(String)
    }

    public let udid: String
    private let capture = FrameCapture()
    private let hid = HIDInjector()
    /// `HIDInjector` is an actor. Input goes through one stream so a touch's
    /// begin, moves and end reach it in the order they were sent.
    private let input: AsyncStream<Input>.Continuation

    public init(udid: String) {
        self.udid = udid
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        input = continuation
        Task { [hid] in
            for await event in stream {
                switch event {
                case .touch(let phase, let x, let y):
                    await hid.sendTouch(type: phase.rawValue, x: x, y: y, screenWidth: 0, screenHeight: 0)
                case .key(let usage, let down):
                    await hid.sendKey(type: down ? "down" : "up", usage: usage)
                case .button(let name):
                    await hid.sendButton(button: name, deviceUDID: udid)
                }
            }
        }
    }

    deinit {
        input.finish()
    }

    /// Starts capture, then input. `onFrame` runs on a capture queue with an
    /// IOSurface-backed `420v` copy of each new frame, taken from a pool.
    public func start(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        try await capture.start(deviceUDID: udid) { pixelBuffer, _, _, _ in
            onFrame(pixelBuffer)
        }
        try await hid.setup(deviceUDID: udid)
    }

    public func stop() async {
        input.finish()
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
}
