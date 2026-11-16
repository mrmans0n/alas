import AlasCore
import Foundation
import Observation

/// Alas's scrcpy client: one session per Android device someone is watching,
/// with its frames fanned out to the screens showing it.
@MainActor
@Observable
final class AndroidStreamClient: DeviceScreenSource, DeviceInput {
    private struct Screen {
        let onFrame: @MainActor (DeviceFrame) -> Void
        let onStop: @MainActor (String) -> Void
    }

    /// Each streamed device's current video size, upright; it changes when the device rotates.
    private(set) var videoSizes: [String: CGSize] = [:]

    @ObservationIgnored private let control: @MainActor () -> AndroidControl?
    @ObservationIgnored private let serverJar: URL?
    @ObservationIgnored private var sessions: [String: AndroidScreenSession] = [:]
    @ObservationIgnored private var screens: [String: [UUID: Screen]] = [:]
    @ObservationIgnored private var subscriptions = StreamSubscriptions()
    @ObservationIgnored private var lastFrames: [String: DeviceFrame] = [:]
    @ObservationIgnored private var metaStates: [String: AndroidMetaState] = [:]
    /// How many times each held key has repeated, by device.
    @ObservationIgnored private var keyRepeats: [String: [UInt32: Int32]] = [:]
    @ObservationIgnored private var clipboardSequence: UInt64 = 0

    init(
        control: @escaping @MainActor () -> AndroidControl?,
        serverJar: URL? = Bundle.main.resourceURL?.appendingPathComponent("scrcpy/scrcpy-server")
    ) {
        self.control = control
        self.serverJar = serverJar
    }

    func subscribe(
        udid: String, onFrame: @escaping @MainActor (DeviceFrame) -> Void, onStop: @escaping @MainActor (String) -> Void
    ) -> UUID {
        let token = UUID()
        screens[udid, default: [:]][token] = Screen(onFrame: onFrame, onStop: onStop)
        // A stream that stopped starts again for a new screen (Retry), however
        // many screens still watch it.
        if subscriptions.add(udid) == .start || sessions[udid] == nil { start(udid) }
        return token
    }

    func unsubscribe(udid: String, token: UUID) {
        screens[udid]?[token] = nil
        if screens[udid]?.isEmpty == true { screens[udid] = nil }
        if subscriptions.remove(udid) == .stop {
            sessions.removeValue(forKey: udid)?.stop()
            lastFrames[udid] = nil
            videoSizes[udid] = nil
            metaStates[udid] = nil
            keyRepeats[udid] = nil
        }
    }

    func touch(udid: String, phase: String, point: DeviceScreenPoint) {
        guard let session = sessions[udid], let size = videoSizes[udid] else { return }
        let action: ScrcpyControl.TouchAction = switch phase {
        case "begin": .down
        case "end": .up
        default: .move
        }
        session.send(ScrcpyControl.touch(
            action, x: Int32(point.x * size.width), y: Int32(point.y * size.height),
            width: UInt16(size.width), height: UInt16(size.height), pressure: action == .up ? 0 : 1
        ))
    }

    func key(udid: String, usage: UInt32, down: Bool) {
        guard let session = sessions[udid] else { return }
        keyRepeats[udid]?[usage] = nil
        metaStates[udid, default: AndroidMetaState()].update(hidUsage: usage, down: down)
        guard let keycode = AndroidKeys.keycode(forHIDUsage: usage) else { return }
        session.send(ScrcpyControl.keycode(down ? .down : .up, keycode: keycode, metastate: metaStates[udid]?.value ?? 0))
    }

    /// Android repeats a held key only when told: each repeat is another down
    /// with a higher count.
    func keyRepeat(udid: String, usage: UInt32) {
        guard let session = sessions[udid], let keycode = AndroidKeys.keycode(forHIDUsage: usage) else { return }
        let count = (keyRepeats[udid]?[usage] ?? 0) + 1
        keyRepeats[udid, default: [:]][usage] = count
        session.send(ScrcpyControl.keycode(.down, keycode: keycode, repeat: count, metastate: metaStates[udid]?.value ?? 0))
    }

    /// Ends every stream and waits for its adb forward to go, for quitting.
    func stopAll() async {
        let running = Array(sessions.values)
        sessions = [:]
        for session in running { await session.stopAndWait() }
    }

    func scroll(udid: String, point: DeviceScreenPoint, dx: Double, dy: Double) {
        guard let session = sessions[udid], let size = videoSizes[udid] else { return }
        session.send(ScrcpyControl.scroll(
            x: Int32(point.x * size.width), y: Int32(point.y * size.height),
            width: UInt16(size.width), height: UInt16(size.height), horizontal: dx, vertical: dy
        ))
    }

    /// A gutter button: back, home, app_switch, power, volume_up, volume_down.
    func button(udid: String, name: String) {
        guard let session = sessions[udid], let keycode = AndroidKeys.button(name) else { return }
        session.send(ScrcpyControl.keycode(.down, keycode: keycode))
        session.send(ScrcpyControl.keycode(.up, keycode: keycode))
    }

    /// Puts `text` on the device's clipboard and pastes it into the focused field.
    func paste(udid: String, text: String) {
        setClipboard(udid: udid, text: text, paste: true)
    }

    /// Sets the device's clipboard; `paste` also pastes it into the focused field.
    func setClipboard(udid: String, text: String, paste: Bool) {
        clipboardSequence += 1
        sessions[udid]?.send(ScrcpyControl.setClipboard(sequence: clipboardSequence, text: text, paste: paste))
    }

    /// Copies the device's selection; nil when nothing came back in 2 s.
    func copy(udid: String) async -> String? {
        await sessions[udid]?.copyClipboard(copy: true)
    }

    /// The device's clipboard as it is; nil when it didn't answer in 2 s.
    func readClipboard(udid: String) async -> String? {
        await sessions[udid]?.copyClipboard(copy: false)
    }

    func lastFrame(udid: String) -> DeviceFrame? {
        lastFrames[udid]
    }

    /// Android snapshots come from `uiautomator` through `AndroidBackend`.
    func describe(udid: String) async throws -> Data {
        throw DeviceToolError(message: "device_unavailable: Android describes its screen through adb.")
    }

    /// Android rotates through `AndroidBackend` and the window manager.
    func rotate(udid: String, to orientation: DeviceScreenOrientation) async throws {
        throw DeviceToolError(message: "device_rotate_failed: Android rotates through adb.")
    }

    private func start(_ serial: String) {
        guard let control = control(), let serverJar, FileManager.default.fileExists(atPath: serverJar.path) else {
            return stopped(serial, reason: "The Android screen server is missing from Alas.")
        }
        let session = AndroidScreenSession(serial: serial, control: control, serverJar: serverJar)
        session.onFrame = { [weak self] frame in self?.deliver(serial, frame) }
        session.onSize = { [weak self] size in self?.videoSizes[serial] = size }
        session.onStop = { [weak self] reason in self?.stopped(serial, reason: reason) }
        sessions[serial] = session
        Task { await session.start() }
    }

    private func deliver(_ serial: String, _ frame: DeviceFrame) {
        lastFrames[serial] = frame
        for screen in screens[serial]?.values.map({ $0 }) ?? [] { screen.onFrame(frame) }
    }

    private func stopped(_ serial: String, reason: String) {
        sessions[serial] = nil
        // The last frame and size were the stopped stream's: a new one must deliver its own
        // before anyone treats the device as ready for input.
        lastFrames[serial] = nil
        videoSizes[serial] = nil
        for screen in screens[serial]?.values.map({ $0 }) ?? [] { screen.onStop(reason) }
    }
}
