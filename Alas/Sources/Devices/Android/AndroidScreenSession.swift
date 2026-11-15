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
    private var clipboardWaiter: CheckedContinuation<String?, Never>?

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
            let scid = String(format: "%08x", UInt32.random(in: 1...0x7FFF_FFFF))
            let port = try await control.adb(serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = UInt16(port) else { throw AndroidControlError("adb didn't forward a port.") }
            self.port = port
            server = try launchServer(scid: scid)
            let video = try await AndroidStreamConnector.connect { try await AndroidSocket.openAnswered(port: number) }
            let controlSocket = try await AndroidSocket.open(port: number)
            guard !stopped else {
                video.close()
                controlSocket.close()
                return
            }
            self.video = video
            self.controlSocket = controlSocket
            _ = try await video.read(exactly: 64) // the device's name
            startPumps(video: video, control: controlSocket)
        } catch {
            fail("The screen couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tearDown()
    }

    func send(_ message: Data) {
        controlSocket?.write(message)
    }

    /// Asks the device to copy its selection and returns it; nil after 2 s.
    func copyClipboard() async -> String? {
        guard controlSocket != nil else { return nil }
        clipboardArrived(nil)
        return await withCheckedContinuation { continuation in
            clipboardWaiter = continuation
            send(ScrcpyControl.getClipboard(copy: true))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.clipboardArrived(nil)
            }
        }
    }

    private func clipboardArrived(_ text: String?) {
        clipboardWaiter?.resume(returning: text)
        clipboardWaiter = nil
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
        AndroidControlPump(socket: control) { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.clipboardArrived(text) } }
        }.start()
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        tearDown()
        onStop(log.tail.map { "\(reason)\n\($0)" } ?? reason)
    }

    private func tearDown() {
        video?.close()
        controlSocket?.close()
        server?.terminationHandler = nil
        server?.terminate()
        clipboardArrived(nil)
        if let port {
            let control = self.control
            let serial = self.serial
            Task { _ = try? await control.adb(serial, ["forward", "--remove", "tcp:\(port)"]) }
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
            decoder.configure(config)
        case .frame(let payload, _):
            guard let image = decoder.decode(payload),
                  let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
            onFrame(surface)
        }
    }
}

/// Reads the control socket's device messages: the clipboard after ⌘C.
final class AndroidControlPump: @unchecked Sendable {
    private let socket: AndroidSocket
    private var parser = ScrcpyDeviceMessageParser()
    private let onClipboard: @Sendable (String) -> Void

    init(socket: AndroidSocket, onClipboard: @escaping @Sendable (String) -> Void) {
        self.socket = socket
        self.onClipboard = onClipboard
    }

    func start() {
        socket.receive { [self] result in
            guard case .success(let data) = result, let messages = try? parser.feed(data) else { return }
            for case .clipboard(let text) in messages { onClipboard(text) }
            start()
        }
    }
}
