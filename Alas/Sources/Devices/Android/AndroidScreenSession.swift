import AlasCore
import CoreVideo
import Foundation
import IOSurface

/// One Android device's scrcpy server, its video and control sockets, and the
/// pumps reading them.
@MainActor
final class AndroidScreenSession {
    static let devicePath = "/data/local/tmp/alas-scrcpy-server.jar"
    private static var formatGeneration: UInt64 = 0
    private static let maxLocalPendingBytes = 8 * 1024 * 1024 + 64 * 1024
    private static let maxLocalPendingPackets = 24

    let serial: String
    var onFrame: (DeviceFrame) -> Void = { _ in }
    var onPacket: (PeerDeviceVideoPacket) -> Void = { _ in }
    var onStop: (String) -> Void = { _ in }

    private let control: AndroidControl
    private let serverJar: URL
    private var server: Process?
    private var startup: Task<Void, Never>?
    private var port: String?
    private var video: AndroidSocket?
    private var videoPump: AndroidVideoPump?
    private var bootstrap = PeerDeviceVideoBootstrap()
    private var wantsLocalVideo = false
    private var localRevision: UInt64 = 0
    private var localDecoding = false
    private var localDecoderRetained = false
    private var localNeedsBootstrap = false
    private var localPending: [PeerDeviceVideoPacket] = []
    private var localPendingBytes = 0
    private var controlSocket: AndroidSocket?
    private let log = ServerLog()
    private var stopped = false
    private let clipboard = LatestReply<String>()
    private let remoteDrain = LatestReply<Bool>()
    private var remoteFrozen = false
    private var remoteQueue: [(UInt64, PeerDeviceInput)] = []
    private var remoteWriting: UInt64?
    private var remoteWriteID: UInt64 = 0
    private var remoteTouch: (x: Double, y: Double)?
    private var remoteKeys: [(usage: UInt32, repeats: Int32)] = []
    private var remoteMeta = AndroidMetaState()
    /// Removes the adb forward; awaited when Alas quits.
    private var forwardRemoval: Task<Void, Never>?

    init(serial: String, control: AndroidControl, serverJar: URL) {
        self.serial = serial
        self.control = control
        self.serverJar = serverJar
    }

    func start(after prior: Task<Void, Never>?) {
        startup = Task { [weak self] in
            await prior?.value
            guard let self, !self.stopped else { return }
            await self.start()
        }
    }

    func setLocalVideo(_ enabled: Bool) {
        guard enabled != wantsLocalVideo else { return }
        wantsLocalVideo = enabled
        localRevision &+= 1
        clearLocalPending()
        localNeedsBootstrap = enabled
        startLocalDecode()
    }

    func replay(_ consume: (PeerDeviceVideoPacket) -> Void) {
        bootstrap.replay(consume)
    }

    func start() async {
        do {
            // A server left from a client that died still holds the device's encoder.
            _ = try? await control.adb(serial, ["shell", "pkill", "-f", "com.genymobile.scrcpy.Server"])
            guard !stopped else { return }
            // The server deletes itself when it exits, so it is pushed every time.
            _ = try await control.adb(serial, ["push", serverJar.path, Self.devicePath], timeout: 60)
            // Stopped while starting: anything acquired from here on is torn down.
            guard !stopped else { return }
            let scid = String(format: "%08x", UInt32.random(in: 1...0x7FFF_FFFF))
            let port = try await control.adb(serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = UInt16(port) else { throw AndroidControlError("adb didn't forward a port.") }
            self.port = port
            guard !stopped else { return tearDown() }
            server = try launchServer(scid: scid)
            let video = try await AndroidStreamConnector.connect(stop: { [weak self] in self?.stopped ?? true }) {
                try await AndroidSocket.openAnswered(port: number)
            }
            self.video = video
            guard !stopped else { return tearDown() }
            let controlSocket = try await AndroidSocket.open(port: number)
            self.controlSocket = controlSocket
            guard !stopped else { return tearDown() }
            _ = try await video.read(exactly: 64) // the device's name
            guard !stopped else { return tearDown() }
            startPumps(video: video, control: controlSocket)
        } catch {
            if stopped {
                tearDown()
            } else {
                fail("The screen couldn't start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tearDown()
    }

    /// Stops, and waits until the adb forward is gone.
    func stopAndWait() async {
        stop()
        await startup?.value
        await forwardRemoval?.value
    }

    func send(_ message: Data) {
        controlSocket?.write(message) { [weak self] failure in
            guard let failure else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(failure) } }
        }
    }

    func remoteInput(formatGeneration: UInt64, event: PeerDeviceInput) {
        guard !remoteFrozen, controlSocket != nil, bootstrap.format?.generation == formatGeneration else { return }
        if case .text(let text) = event, text.utf8.count > 4_096 { return }
        if case .pointer(.move, _, _) = event,
           case let (generation, .pointer(.move, _, _))? = remoteQueue.last, generation == formatGeneration {
            remoteQueue[remoteQueue.count - 1] = (formatGeneration, event)
        } else {
            guard remoteQueue.count < 64 else { return fail("The Android screen stopped accepting input.") }
            remoteQueue.append((formatGeneration, event))
        }
        sendNextRemoteInput()
    }

    /// Called in the same main-actor turn that invalidates the host lease.
    func freezeRemoteInput() {
        remoteFrozen = true
        remoteQueue.removeAll(keepingCapacity: true)
    }

    /// Drain the submitted event before sending releases on the same socket.
    /// scrcpy 5.0.1 has no input ACK. This orders socket writes, not Android
    /// dispatch versus work submitted over a separate ADB connection.
    func releaseRemoteInput() async {
        freezeRemoteInput()
        defer { remoteFrozen = false }
        guard await waitForRemoteWrite() else { return }
        sendHeldInputReleases()
        _ = await waitForRemoteWrite()
    }

    private func waitForRemoteWrite() async -> Bool {
        guard !stopped else { return false }
        guard remoteWriting != nil else { return true }
        let reply = await remoteDrain.request(timeout: .seconds(1)) {
            if remoteWriting == nil { remoteDrain.deliver(true) }
        }
        if reply.value != true, !stopped { fail("The Android screen didn't release its input.") }
        return !stopped
    }

    private func sendHeldInputReleases() {
        var cleanup = Data()
        if let (x, y) = remoteTouch, let position = position(x: x, y: y) {
            cleanup = cancelTouch(at: position)
        }
        remoteTouch = nil
        for key in remoteKeys.reversed() {
            remoteMeta.update(hidUsage: key.usage, down: false)
            if let code = AndroidKeys.keycode(forHIDUsage: key.usage) {
                cleanup.append(ScrcpyControl.keycode(.up, keycode: code, metastate: remoteMeta.value))
            }
        }
        remoteKeys.removeAll(keepingCapacity: true)
        remoteMeta = AndroidMetaState()
        if !cleanup.isEmpty { sendRemote(cleanup) }
    }

    private func sendNextRemoteInput() {
        guard !remoteFrozen, remoteWriting == nil else { return }
        while !remoteQueue.isEmpty {
            let (generation, event) = remoteQueue.removeFirst()
            guard generation == bootstrap.format?.generation, let message = remoteMessage(event) else { continue }
            sendRemote(message)
            return
        }
    }

    private func sendRemote(_ message: Data) {
        guard let controlSocket else { return }
        remoteWriteID &+= 1
        let id = remoteWriteID
        remoteWriting = id
        controlSocket.write(message) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    if let error { return self.fail(error) }
                    guard self.remoteWriting == id else { return }
                    self.remoteWriting = nil
                    self.remoteDrain.deliver(true)
                    self.sendNextRemoteInput()
                }
            }
        }
    }

    private typealias InputPosition = (x: Int32, y: Int32, width: UInt16, height: UInt16)

    private func position(x: Double, y: Double) -> InputPosition? {
        guard (0...1).contains(x), (0...1).contains(y),
              case .format(_, let width, let height)? = bootstrap.format else { return nil }
        return (
            min(Int32(x * Double(width)), Int32(width) - 1),
            min(Int32(y * Double(height)), Int32(height) - 1),
            UInt16(width), UInt16(height)
        )
    }

    private func touch(_ action: ScrcpyControl.TouchAction, at position: InputPosition) -> Data {
        ScrcpyControl.touch(
            action, x: position.x, y: position.y, width: position.width, height: position.height,
            pressure: action == .up ? 0 : 1
        )
    }

    private func cancelTouch(at position: InputPosition) -> Data {
        ScrcpyControl.cancelTouch(x: position.x, y: position.y, width: position.width, height: position.height)
    }

    private func remoteMessage(_ event: PeerDeviceInput) -> Data? {
        switch event {
        case .pointer(let phase, let x, let y):
            if phase == .cancel {
                guard let (x, y) = remoteTouch, let position = position(x: x, y: y) else { return nil }
                remoteTouch = nil
                return cancelTouch(at: position)
            }
            guard let position = position(x: x, y: y) else { return nil }
            switch phase {
            case .begin:
                guard remoteTouch == nil else { return nil }
                remoteTouch = (x, y)
                return touch(.down, at: position)
            case .move:
                guard remoteTouch != nil else { return nil }
                remoteTouch = (x, y)
                return touch(.move, at: position)
            case .end:
                guard remoteTouch != nil else { return nil }
                remoteTouch = nil
                return touch(.up, at: position)
            case .cancel:
                return nil
            }
        case .key(let usage, let down):
            guard let code = AndroidKeys.keycode(forHIDUsage: usage) else { return nil }
            var repeats: Int32 = 0
            if let index = remoteKeys.firstIndex(where: { $0.usage == usage }) {
                if down {
                    repeats = min(remoteKeys[index].repeats, .max - 1) + 1
                    remoteKeys[index].repeats = repeats
                } else {
                    remoteKeys.remove(at: index)
                }
            } else if down {
                remoteKeys.append((usage, 0))
            } else {
                return nil
            }
            remoteMeta.update(hidUsage: usage, down: down)
            return ScrcpyControl.keycode(down ? .down : .up, keycode: code, repeat: repeats, metastate: remoteMeta.value)
        case .text(let text):
            guard !text.isEmpty else { return nil }
            // Use the existing UTF-8 paste mechanism, without clipboard sync.
            // INJECT_TEXT can't type characters outside Android's key map.
            return ScrcpyControl.setClipboard(sequence: 0, text: text, paste: true)
        case .scroll(let x, let y, let dx, let dy):
            guard let position = position(x: x, y: y), dx.isFinite, dy.isFinite else { return nil }
            return ScrcpyControl.scroll(
                x: position.x, y: position.y, width: position.width, height: position.height, horizontal: dx, vertical: dy
            )
        case .button(let button):
            let name = button == .recents ? "app_switch" : button.rawValue
            guard let code = AndroidKeys.button(name) else { return nil }
            return ScrcpyControl.keycode(.down, keycode: code) + ScrcpyControl.keycode(.up, keycode: code)
        }
    }

    /// The device's text clipboard. scrcpy sends no reply when Android has no
    /// text clipboard, so a timeout from a still-running session means empty.
    func copyClipboard(copy: Bool) async -> String? {
        guard controlSocket != nil else { return nil }
        let reply = await clipboard.request(timeout: .seconds(2)) { send(ScrcpyControl.getClipboard(copy: copy)) }
        return Self.resolveClipboardReply(reply, stopped: stopped)
    }

    static func resolveClipboardReply(_ reply: LatestReplyOutcome<String>, stopped: Bool) -> String? {
        switch reply {
        case .value(let text):
            text
        case .timedOut:
            stopped ? nil : ""
        case .replaced, .cancelled:
            nil
        }
    }

    private func launchServer(scid: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: control.sdk.adb)
        process.arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.devicePath) app_process / com.genymobile.scrcpy.Server 5.0.1 scid=\(scid) "
                + "tunnel_forward=true audio=false control=true max_size=1600 clipboard_autosync=false "
                + "video_bit_rate=4000000 video_codec_options=i-frame-interval:int=1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = self.log
        pipe.fileHandleForReading.readabilityHandler = { log.append($0.availableData) }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail("The screen stopped.") } }
        }
        try process.run()
        return process
    }

    private func startPumps(video: AndroidSocket, control: AndroidSocket) {
        let pump = AndroidVideoPump(
            socket: video,
            onEvents: { [weak self] events, next in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.stopped else { return }
                        self.deliver(events)
                        if !self.stopped { next() }
                    }
                }
            },
            onDecoded: { [weak self] result, revision in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.stopped else { return }
                        self.localDecoding = false
                        if let (surface, generation) = result, self.wantsLocalVideo, self.localRevision == revision,
                           self.bootstrap.format?.generation == generation {
                            self.onFrame(DeviceFrame(surface: surface, orientation: .portrait))
                        }
                        self.startLocalDecode()
                    }
                }
            },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(reason) } }
            }
        )
        videoPump = pump
        pump.start()
        AndroidControlPump(
            socket: control,
            onClipboard: { [weak self] text in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.clipboard.deliver(text) } }
            },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(reason) } }
            }
        ).start()
    }

    private func deliver(_ events: [ScrcpyVideoEvent]) {
        for event in events {
            guard !stopped else { return }
            let packet: PeerDeviceVideoPacket
            switch event {
            case .session(let width, let height):
                guard (1...8192).contains(width), (1...8192).contains(height) else {
                    return fail("The device sent an invalid screen size.")
                }
                Self.formatGeneration &+= 1
                packet = .format(generation: Self.formatGeneration, width: UInt32(width), height: UInt32(height))
            case .config(let bytes):
                guard let generation = bootstrap.format?.generation else { continue }
                packet = .config(generation: generation, bytes: bytes)
            case .frame(let bytes, let pts, let key):
                guard let generation = bootstrap.format?.generation else { continue }
                packet = .frame(generation: generation, pts: pts, keyFrame: key, bytes: bytes)
            }
            bootstrap.update(packet)
            if case .format = packet {
                // The position mapper has already changed on the device. Release the old
                // finger with the new dimensions, which the server is now willing to accept.
                remoteQueue.removeAll(keepingCapacity: true)
                if !remoteFrozen { sendHeldInputReleases() }
            }
            enqueueLocal(packet)
            onPacket(packet)
        }
        startLocalDecode()
    }

    private func enqueueLocal(_ packet: PeerDeviceVideoPacket) {
        guard wantsLocalVideo else { return }
        let bytes: Int
        switch packet {
        case .format:
            clearLocalPending()
            localNeedsBootstrap = false
            bytes = 0
        case .config(_, let data), .frame(_, _, _, let data):
            guard !localNeedsBootstrap else { return }
            bytes = data.count
        }
        guard localPending.count < Self.maxLocalPendingPackets, bytes <= Self.maxLocalPendingBytes - localPendingBytes else {
            clearLocalPending()
            localNeedsBootstrap = true
            return
        }
        localPendingBytes += bytes
        localPending.append(packet)
    }

    private func clearLocalPending() {
        localPending.removeAll(keepingCapacity: true)
        localPendingBytes = 0
    }

    /// One batch at a time. If live decode falls behind, discard its backlog and
    /// restart from the bounded GOP cache (or wait for a keyframe).
    private func startLocalDecode() {
        guard !stopped, !localDecoding, let videoPump else { return }
        guard wantsLocalVideo else {
            if localDecoderRetained {
                localDecoderRetained = false
                videoPump.resetLocalDecoder()
            }
            return
        }
        if localNeedsBootstrap {
            localNeedsBootstrap = false
            bootstrap.replay { localPending.append($0) }
        }
        guard !localPending.isEmpty else { return }
        let packets = localPending
        localPending = []
        localPendingBytes = 0
        localDecoding = true
        localDecoderRetained = true
        videoPump.decodeLocal(packets, revision: localRevision)
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        tearDown()
        onStop(log.tail.map { "\(reason)\n\($0)" } ?? reason)
    }

    /// Safe to run again: a session stopped while starting runs it once more
    /// for what it acquired afterwards.
    private func tearDown() {
        video?.close()
        self.video = nil
        videoPump?.resetLocalDecoder()
        videoPump = nil
        clearLocalPending()
        controlSocket?.close()
        controlSocket = nil
        remoteDrain.cancel()
        remoteQueue.removeAll()
        remoteWriting = nil
        remoteTouch = nil
        remoteKeys.removeAll()
        remoteMeta = AndroidMetaState()
        server?.terminationHandler = nil
        server?.terminate()
        server = nil
        clipboard.cancel()
        if let port {
            self.port = nil
            let control = self.control
            let serial = self.serial
            forwardRemoval = Task { _ = try? await control.adb(serial, ["forward", "--remove", "tcp:\(port)"]) }
        }
    }
}

/// The server's last output lines, for the stopped screen's detail.
final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            lines += text.split(whereSeparator: \.isNewline).map(String.init)
            lines = Array(lines.suffix(5))
        }
    }

    var tail: String? {
        lock.withLock { lines.isEmpty ? nil : lines.joined(separator: "\n") }
    }
}

/// Parses on the socket queue, then feeds VideoToolbox on a separate per-device
/// queue when there are local frame consumers. Neither queue waits on a viewer.
private final class AndroidVideoPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyVideoParser()
    private let decodeQueue = DispatchQueue(label: "io.nlopez.alas.android-decode")
    private var decoder: H264Decoder?
    private var config: Data?
    private let onEvents: @Sendable ([ScrcpyVideoEvent], @escaping @Sendable () -> Void) -> Void
    private let onDecoded: @Sendable ((IOSurface, UInt64)?, UInt64) -> Void
    private let onEnd: @Sendable (String) -> Void

    init(
        socket: AndroidSocket,
        onEvents: @escaping @Sendable ([ScrcpyVideoEvent], @escaping @Sendable () -> Void) -> Void,
        onDecoded: @escaping @Sendable ((IOSurface, UInt64)?, UInt64) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) {
        self.socket = socket
        self.onEvents = onEvents
        self.onDecoded = onDecoded
        self.onEnd = onEnd
    }

    func start() {
        socket.receive { [self] result in
            switch result {
            case .failure:
                onEnd("The screen stopped.")
            case .success(let data):
                do {
                    let events = try parser.feed(data)
                    if events.isEmpty { start() }
                    else { onEvents(events) { self.start() } }
                } catch {
                    onEnd("The device sent video Alas can't read.")
                }
            }
        }
    }

    func resetLocalDecoder() {
        decodeQueue.async { [self] in
            config = nil
            decoder = nil
        }
    }

    func decodeLocal(_ packets: [PeerDeviceVideoPacket], revision: UInt64) {
        decodeQueue.async { [self] in
            var newest: (IOSurface, UInt64)?
            for packet in packets {
                switch packet {
                case .format:
                    decoder = nil
                    config = nil
                    newest = nil
                case .config(_, let bytes):
                    decoder = nil
                    config = bytes
                case .frame(let generation, _, let key, let bytes):
                    if decoder == nil {
                        guard key, let config else { continue }
                        let candidate = H264Decoder()
                        guard candidate.configure(config) else { continue }
                        decoder = candidate
                    }
                    guard let image = decoder?.decode(bytes),
                          let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
                        decoder = nil
                        continue
                    }
                    newest = (surface, generation)
                }
            }
            onDecoded(newest, revision)
        }
    }
}

/// Reads the control socket's device messages: the clipboard after ⌘C. Its
/// end ends the session, since input goes through the same socket.
final class AndroidControlPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyDeviceMessageParser()
    private let onClipboard: @Sendable (String) -> Void
    private let onEnd: @Sendable (String) -> Void

    init(socket: AndroidSocket, onClipboard: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (String) -> Void) {
        self.socket = socket
        self.onClipboard = onClipboard
        self.onEnd = onEnd
    }

    func start() {
        socket.receive { [self] result in
            guard case .success(let data) = result else { return onEnd("The screen stopped taking input.") }
            guard let messages = try? parser.feed(data) else { return onEnd("The device sent a message Alas can't read.") }
            for case .clipboard(let text) in messages { onClipboard(text) }
            start()
        }
    }
}
