import AlasCore
import Foundation
import Observation

/// What the Logs tab reads from: a simulator's unified log, or an Android
/// device's logcat.
@MainActor
protocol DeviceLogSource: AnyObject {
    /// iOS: Apple's subsystems can be included.
    var hasAppleSubsystems: Bool { get }
    func userApps() async -> [SimulatorApp]
    /// The app in front now and each time it changes, until the task ends; nil while none is.
    func frontApps() -> AsyncStream<String?>
    /// Streams lines into `stream` for `app` (nil: every process).
    func start(_ stream: SimulatorLogStream, app: String?, level: SimulatorLogLevel, includeApple: Bool) async
    func crashes(app: String?, since: Date) async -> [SimulatorCrashReport]
    /// The tab went away.
    func stop()
}

/// A simulator's unified log through `log stream`, SpringBoard's foreground
/// tracker and `.ips` crash reports.
@MainActor
final class SimulatorLogSource: DeviceLogSource {
    let hasAppleSubsystems = true
    private let udid: String
    private let tracker: () -> SimulatorForegroundTracker
    private var executables: [String: String] = [:]

    init(udid: String, tracker: @escaping () -> SimulatorForegroundTracker) {
        self.udid = udid
        self.tracker = tracker
    }

    func userApps() async -> [SimulatorApp] {
        (try? await SimulatorControl.userApps(udid: udid)) ?? []
    }

    func frontApps() -> AsyncStream<String?> {
        let tracker = tracker()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                var last = await tracker.bundleID()
                continuation.yield(last)
                while !Task.isCancelled {
                    // Wakes on the tracker's next change.
                    await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                        withObservationTracking { _ = tracker.current } onChange: { changed.resume() }
                    }
                    let now = tracker.current
                    if now != last {
                        last = now
                        continuation.yield(now)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(_ stream: SimulatorLogStream, app: String?, level: SimulatorLogLevel, includeApple: Bool) async {
        var executable: String?
        if let app {
            guard let found = await self.executable(for: app) else { return }
            executable = found
        }
        stream.start(udid: udid, query: SimulatorLogQuery(executable: executable, level: level, includeApple: includeApple))
    }

    private func executable(for bundleID: String) async -> String? {
        if let known = executables[bundleID] { return known }
        executables = (try? await SimulatorControl.appExecutables(udid: udid)) ?? executables
        return executables[bundleID]
    }

    func crashes(app: String?, since: Date) async -> [SimulatorCrashReport] {
        SimulatorControl.crashReports(udid: udid, bundleID: app, since: since)
    }

    func stop() {}
}
