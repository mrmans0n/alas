import AlasCore
import Foundation

/// One running `adb shell screenrecord`, which stops by itself after 3 minutes.
@MainActor
final class AndroidScreenRecording: ScreenRecording {
    var onExit: ((Bool) -> Void)?

    private let control: AndroidControl
    private let serial: String
    private let file: URL
    private let remote = "/sdcard/alas-recording-\(UUID().uuidString.prefix(8)).mp4"
    private let process = Process()
    private var stopping = false

    init(control: AndroidControl, serial: String, file: URL) throws {
        self.control = control
        self.serial = serial
        self.file = file
        process.executableURL = URL(fileURLWithPath: control.sdk.adb)
        process.arguments = ["-s", serial, "shell", "screenrecord", "--time-limit", "180", remote]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.endedByItself() } }
        }
        try process.run()
    }

    func stop() async -> Bool {
        stopping = true
        // SIGINT lets screenrecord finish the file.
        _ = try? await control.adb(serial, ["shell", "pkill", "-INT", "screenrecord"])
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await pull()
    }

    private func endedByItself() {
        guard !stopping else { return }
        Task { onExit?(await pull()) }
    }

    /// Copies the video to `file` and deletes it from the device.
    private func pull() async -> Bool {
        let pulled = (try? await control.adb(serial, ["pull", remote, file.path], timeout: 120)) != nil
        _ = try? await control.adb(serial, ["shell", "rm", "-f", remote])
        return pulled && FileManager.default.fileExists(atPath: file.path)
    }
}
