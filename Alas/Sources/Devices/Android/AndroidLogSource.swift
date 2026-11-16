import AlasCore
import Foundation

/// An Android device's logcat: the app in front from the activity manager,
/// one app's lines by its pid (followed across restarts), and Java crashes.
@MainActor
final class AndroidLogSource: DeviceLogSource {
    let hasAppleSubsystems = false
    private let serial: String
    private let control: AndroidControl
    private var following: Task<Void, Never>?

    init(serial: String, control: AndroidControl) {
        self.serial = serial
        self.control = control
    }

    func userApps() async -> [SimulatorApp] {
        let output = (try? await control.adb(serial, ["shell", "pm", "list", "packages", "-3"])) ?? ""
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            let package = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
            return SimulatorApp(bundleID: package, name: package)
        }.sorted { $0.bundleID < $1.bundleID }
    }

    func frontApps() -> AsyncStream<String?> {
        let control = control
        let serial = serial
        return AsyncStream { continuation in
            let task = Task {
                var last: String??
                while !Task.isCancelled {
                    let output = (try? await control.adb(serial, ["shell", "dumpsys", "activity", "activities"])) ?? ""
                    let front = AndroidLogcat.frontmostPackage(output)
                    if last != .some(front) {
                        last = .some(front)
                        continuation.yield(front)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(_ stream: SimulatorLogStream, app: String?, level: SimulatorLogLevel, includeApple: Bool) async {
        following?.cancel()
        // The previous source's lines stop now, even if the new app isn't running yet.
        stream.stop()
        guard let app else {
            run(stream, pid: nil, level: level)
            return
        }
        // The app's pid changes when it restarts: look again every 2 s and follow it.
        following = Task { [weak self] in
            var running: Int?
            while !Task.isCancelled, let self {
                let found = (try? await self.control.adb(self.serial, ["shell", "pidof", app]))?
                    .split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
                // Replaced while asking: the stream is the new source's now.
                guard !Task.isCancelled else { return }
                switch AndroidLogFollow.next(running: running, found: found) {
                case .keep: break
                case .restart(let pid):
                    running = pid
                    self.run(stream, pid: pid, level: level)
                case .waitForApp:
                    if running != nil { stream.stop() }
                    running = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func run(_ stream: SimulatorLogStream, pid: Int?, level: SimulatorLogLevel) {
        let year = Calendar.current.component(.year, from: Date())
        var args = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1"]
        if let pid { args.append("--pid=\(pid)") }
        args.append("*:\(AndroidLogcat.filter(level))")
        stream.start(executable: control.sdk.adb, args: args, name: "adb logcat") { line in
            AndroidLogcat.parse(String(decoding: line, as: UTF8.self), year: year).first
        }
    }

    func crashes(app: String?, since: Date) async -> [SimulatorCrashReport] {
        guard let app else { return [] }
        let seconds = Int(Date().timeIntervalSince(since).rounded(.up))
        let output = (try? await control.adb(serial, [
            "shell", "logcat -d -b crash -v threadtime -T \(AndroidLogcat.since(seconds: seconds))",
        ])) ?? ""
        let year = Calendar.current.component(.year, from: Date())
        return AndroidLogcat.crashes(AndroidLogcat.parse(output, year: year), package: app).map { $0.report(bundleID: app) }
    }

    func stop() {
        following?.cancel()
        following = nil
    }
}
