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
    /// Pulling the video, once, whichever ends the recording.
    private var finishing: Task<Bool, Never>?

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
        return await finish().value
    }

    private func endedByItself() {
        guard !stopping else { return }
        Task { onExit?(await finish().value) }
    }

    private func finish() -> Task<Bool, Never> {
        if let finishing { return finishing }
        let task = Task { await pull() }
        finishing = task
        return task
    }

    /// Copies the video to `file`, then deletes it from the device; a video
    /// that didn't copy stays there.
    private func pull() async -> Bool {
        let pulled = (try? await control.adb(serial, ["pull", remote, file.path], timeout: 120)) != nil
        guard pulled, FileManager.default.fileExists(atPath: file.path) else { return false }
        _ = try? await control.adb(serial, ["shell", "rm", "-f", remote])
        return true
    }
}
