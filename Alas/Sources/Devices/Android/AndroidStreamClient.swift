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

    private struct EncodedScreen {
        let onPacket: @MainActor (PeerDeviceVideoPacket) -> Void
        let onStop: @MainActor (String) -> Void
    }

    private struct Retiring {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Each streamed device's current video size, upright; it changes when the device rotates.
    private(set) var videoSizes: [String: CGSize] = [:]

    @ObservationIgnored private let control: @MainActor () -> AndroidControl?
    @ObservationIgnored private let serverJar: URL?
    @ObservationIgnored private var sessions: [String: AndroidScreenSession] = [:]
    @ObservationIgnored private var screens: [String: [UUID: Screen]] = [:]
    @ObservationIgnored private var encodedScreens: [String: [UUID: EncodedScreen]] = [:]
    @ObservationIgnored private var retiring: [String: Retiring] = [:]
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
        if let session = sessions[udid] {
            session.setLocalVideo(true)
            if let frame = lastFrames[udid] { onFrame(frame) }
        } else {
            start(udid)
        }
        return token
    }

    func unsubscribe(udid: String, token: UUID) {
        guard screens[udid]?.removeValue(forKey: token) != nil else { return }
        if screens[udid]?.isEmpty == true {
            screens[udid] = nil
            lastFrames[udid] = nil
            sessions[udid]?.setLocalVideo(false)
            stopIfUnwatched(udid)
        }
    }

    func subscribeEncoded(
        serial: String, onPacket: @escaping @MainActor (PeerDeviceVideoPacket) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID {
        let token = UUID()
        encodedScreens[serial, default: [:]][token] = EncodedScreen(onPacket: onPacket, onStop: onStop)
        if let session = sessions[serial] {
            session.replay(onPacket)
        } else {
            start(serial)
        }
        return token
    }

    func unsubscribeEncoded(serial: String, token: UUID) {
        guard encodedScreens[serial]?.removeValue(forKey: token) != nil else { return }
        if encodedScreens[serial]?.isEmpty == true {
            encodedScreens[serial] = nil
            stopIfUnwatched(serial)
        }
    }

    func remoteInput(serial: String, formatGeneration: UInt64, event: PeerDeviceInput) {
        sessions[serial]?.remoteInput(formatGeneration: formatGeneration, event: event)
    }

    func freezeRemoteInput(serial: String) {
        sessions[serial]?.freezeRemoteInput()
    }

    func releaseRemoteInput(serial: String) async {
        await sessions[serial]?.releaseRemoteInput()
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
        let running = sessions
        sessions.removeAll()
        for (serial, session) in running {
            clearCaptureState(serial)
            retire(session, serial: serial)
        }
        for cleanup in Array(retiring.values) { await cleanup.task.value }
    }

    var takesScroll: Bool { true }

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
            let reason = "The Android screen server is missing from Alas."
            for screen in screens[serial]?.values ?? [:].values { screen.onStop(reason) }
            Task { [weak self] in
                guard let self, self.sessions[serial] == nil else { return }
                self.notifyEncodedStopped(serial, reason: reason)
            }
            return
        }
        let session = AndroidScreenSession(serial: serial, control: control, serverJar: serverJar)
        session.onFrame = { [weak self, weak session] frame in
            guard let self, let session, self.sessions[serial] === session else { return }
            self.deliver(serial, frame)
        }
        session.onPacket = { [weak self, weak session] packet in
            guard let self, let session, self.sessions[serial] === session else { return }
            if case .format(_, let width, let height) = packet {
                self.lastFrames[serial] = nil
                self.videoSizes[serial] = CGSize(width: Int(width), height: Int(height))
            }
            for screen in self.encodedScreens[serial]?.values ?? [:].values {
                screen.onPacket(packet)
            }
        }
        session.onStop = { [weak self, weak session] reason in
            guard let self, let session, self.sessions[serial] === session else { return }
            self.sessions[serial] = nil
            self.clearCaptureState(serial)
            self.retire(session, serial: serial)
            self.notifyStopped(serial, reason: reason)
        }
        sessions[serial] = session
        session.setLocalVideo(screens[serial] != nil)
        session.start(after: retiring[serial]?.task)
    }

    private func deliver(_ serial: String, _ frame: DeviceFrame) {
        lastFrames[serial] = frame
        for screen in screens[serial]?.values ?? [:].values { screen.onFrame(frame) }
    }

    private func stopIfUnwatched(_ serial: String) {
        guard screens[serial] == nil, encodedScreens[serial] == nil else { return }
        if let session = sessions.removeValue(forKey: serial) { retire(session, serial: serial) }
        clearCaptureState(serial)
    }

    private func retire(_ session: AndroidScreenSession, serial: String) {
        session.stop()
        let id = UUID()
        let task = Task { [weak self] in
            await session.stopAndWait()
            if self?.retiring[serial]?.id == id { self?.retiring[serial] = nil }
        }
        retiring[serial] = Retiring(id: id, task: task)
    }

    private func clearCaptureState(_ serial: String) {
        lastFrames[serial] = nil
        videoSizes[serial] = nil
        metaStates[serial] = nil
        keyRepeats[serial] = nil
    }

    private func notifyStopped(_ serial: String, reason: String) {
        for screen in screens[serial]?.values ?? [:].values { screen.onStop(reason) }
        notifyEncodedStopped(serial, reason: "The Android screen stopped.")
    }

    private func notifyEncodedStopped(_ serial: String, reason: String) {
        for screen in encodedScreens[serial]?.values ?? [:].values {
            screen.onStop(reason)
        }
    }
}
