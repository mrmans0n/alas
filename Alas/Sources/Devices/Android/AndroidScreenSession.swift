import AlasCore
import CoreVideo
import Foundation
import IOSurface

/// One Android device's scrcpy server, its video and control sockets, and the
/// pumps reading them.
@MainActor
final class AndroidScreenSession {
    static let devicePath = "/data/local/tmp/alas-scrcpy-server.jar"

    let serial: String
    var onFrame: (DeviceFrame) -> Void = { _ in }
    var onSize: (CGSize) -> Void = { _ in }
    var onStop: (String) -> Void = { _ in }

    private let control: AndroidControl
    private let serverJar: URL
    private var server: Process?
    private var port: String?
    private var video: AndroidSocket?
    private var controlSocket: AndroidSocket?
    private let log = ServerLog()
    private var stopped = false
    private let clipboard = LatestReply<String>()
    /// Removes the adb forward; awaited when Alas quits.
    private var forwardRemoval: Task<Void, Never>?

    init(serial: String, control: AndroidControl, serverJar: URL) {
        self.serial = serial
        self.control = control
        self.serverJar = serverJar
    }

    func start() async {
        do {
            // A server left from a client that died still holds the device's encoder.
            _ = try? await control.adb(serial, ["shell", "pkill", "-f", "com.genymobile.scrcpy.Server"])
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
            let controlSocket = try await AndroidSocket.open(port: number)
            self.controlSocket = controlSocket
            guard !stopped else { return tearDown() }
            _ = try await video.read(exactly: 64) // the device's name
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
        await forwardRemoval?.value
    }

    func send(_ message: Data) {
        controlSocket?.write(message) { [weak self] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(reason) } }
        }
    }

    /// The device's text clipboard. scrcpy sends no reply when Android has no
    /// text clipboard, so a timeout from a still-running session means empty.
    func copyClipboard(copy: Bool) async -> String? {
        guard controlSocket != nil else { return nil }
        let reply = await clipboard.request(timeout: .seconds(2)) { send(ScrcpyControl.getClipboard(copy: copy)) }
        return Self.resolveClipboardReply(reply, stopped: stopped)
    }

    static func resolveClipboardReply(_ reply: String?, stopped: Bool) -> String? {
        if let reply { return reply }
        return stopped ? nil : ""
    }

    private func launchServer(scid: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: control.sdk.adb)
        process.arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.devicePath) app_process / com.genymobile.scrcpy.Server 5.0.1 scid=\(scid) "
                + "tunnel_forward=true audio=false control=true max_size=1600 clipboard_autosync=false",
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
        AndroidVideoPump(
            socket: video,
            onSize: { [weak self] width, height in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSize(CGSize(width: width, height: height)) } }
            },
            onFrame: { [weak self] surface in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onFrame(DeviceFrame(surface: surface, orientation: .portrait)) }
                }
            },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(reason) } }
            }
        ).start()
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
        controlSocket?.close()
        server?.terminationHandler = nil
        server?.terminate()
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

/// Reads the video socket on the socket's queue and decodes as it goes.
final class AndroidVideoPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyVideoParser()
    private let decoder = H264Decoder()
    private let onSize: @Sendable (Int, Int) -> Void
    private let onFrame: @Sendable (IOSurface) -> Void
    private let onEnd: @Sendable (String) -> Void
    /// The decoder couldn't take the stream's format or a key frame.
    private var failed = false

    init(
        socket: AndroidSocket, onSize: @escaping @Sendable (Int, Int) -> Void,
        onFrame: @escaping @Sendable (IOSurface) -> Void, onEnd: @escaping @Sendable (String) -> Void
    ) {
        self.socket = socket
        self.onSize = onSize
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    func start() {
        socket.receive { [self] result in
            switch result {
            case .failure:
                onEnd("The screen stopped.")
            case .success(let data):
                do {
                    for event in try parser.feed(data) { handle(event) }
                    if failed { return onEnd("The device's video couldn't be decoded.") }
                    start()
                } catch {
                    onEnd("The device sent video Alas can't read.")
                }
            }
        }
    }

    private func handle(_ event: ScrcpyVideoEvent) {
        switch event {
        case .session(let width, let height):
            onSize(width, height)
        case .config(let config):
            if !decoder.configure(config) { failed = true }
        case .frame(let payload, let keyFrame):
            guard let image = decoder.decode(payload),
                  let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
                // A key frame starts the picture over; without it the screen stays blank.
                if keyFrame { failed = true }
                return
            }
            onFrame(surface)
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
