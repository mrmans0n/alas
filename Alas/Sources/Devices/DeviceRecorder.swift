import Foundation
import Observation

/// One running `simctl io recordVideo`.
@MainActor
protocol ScreenRecording: AnyObject {
    /// Ends the recording; true when the video was written.
    func stop() async -> Bool
    /// Called once when the recording ends by itself, with whether the video was written.
    var onExit: ((Bool) -> Void)? { get set }
}

/// Screen recordings of simulators: at most one per simulator, by you or by
/// an agent session.
@MainActor
@Observable
final class DeviceRecorder {
    enum Owner: Equatable, Sendable {
        case user
        case agent(sessionID: String)
    }

    struct Finished: Equatable {
        let file: URL
        let seconds: Double
    }

    enum Failure: Error, Equatable {
        case busy(Owner)
        case notRecording
        case failed(String)
    }

    private struct Running {
        let owner: Owner
        let file: URL
        let startedAt: Date
        let recording: any ScreenRecording
        let limit: Task<Void, Never>?
    }

    /// A recording of yours that ended by itself (its simulator shut down):
    /// nobody will press Stop for it, so it is handed on to be saved.
    @ObservationIgnored var onUserRecordingEnded: ((String, Finished) -> Void)?
    private var running: [String: Running] = [:]
    /// Recordings that ended by themselves, kept for their owner's `stop`.
    @ObservationIgnored private var ended: [String: (owner: Owner, result: Result<Finished, Failure>)] = [:]
    @ObservationIgnored private let startRecording: @MainActor (String, URL) throws -> any ScreenRecording
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let agentLimit: Duration

    init(
        start: @escaping @MainActor (String, URL) throws -> any ScreenRecording,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        agentLimit: Duration = .seconds(600)
    ) {
        startRecording = start
        self.now = now
        self.sleep = sleep
        self.agentLimit = agentLimit
    }

    /// Who records the simulator now.
    func owner(udid: String) -> Owner? {
        running[udid]?.owner
    }

    func start(udid: String, owner: Owner, file: URL) throws(Failure) {
        if let current = running[udid] { throw .busy(current.owner) }
        ended[udid] = nil
        let recording: any ScreenRecording
        do {
            recording = try startRecording(udid, file)
        } catch {
            throw .failed(error.localizedDescription)
        }
        let startedAt = now()
        recording.onExit = { [weak self] written in self?.endedByItself(udid: udid, recording: recording, written: written) }
        // An agent may forget to stop; its recording ends after the limit.
        let limit: Task<Void, Never>? = owner == .user ? nil : Task { [weak self, sleep, agentLimit] in
            await sleep(agentLimit)
            guard !Task.isCancelled else { return }
            await self?.stopByItself(udid: udid, recording: recording)
        }
        running[udid] = Running(owner: owner, file: file, startedAt: startedAt, recording: recording, limit: limit)
    }

    func stop(udid: String, owner: Owner) async throws(Failure) -> Finished {
        if let current = running[udid], current.owner == owner {
            running[udid] = nil
            current.limit?.cancel()
            let written = await Self.finish(current.recording)
            return try finished(current, written: written).get()
        }
        if let kept = ended[udid], kept.owner == owner {
            ended[udid] = nil
            return try kept.result.get()
        }
        throw .notRecording
    }

    /// The simulator shut down: its recording ends, kept for its owner.
    func simulatorStopped(udid: String) async {
        guard let current = running[udid] else { return }
        await stopByItself(udid: udid, recording: current.recording)
    }

    private func stopByItself(udid: String, recording: any ScreenRecording) async {
        guard let current = running[udid], current.recording === recording else { return }
        running[udid] = nil
        // This may run inside the limit task, which the cancel below reaches.
        current.limit?.cancel()
        let written = await Self.finish(recording)
        keep(current, udid: udid, result: finished(current, written: written))
    }

    private func endedByItself(udid: String, recording: any ScreenRecording, written: Bool) {
        guard let current = running[udid], current.recording === recording else { return }
        running[udid] = nil
        current.limit?.cancel()
        keep(current, udid: udid, result: finished(current, written: written))
    }

    /// Keeps an agent's ended recording for its next stop; hands yours on at once.
    private func keep(_ recording: Running, udid: String, result: Result<Finished, Failure>) {
        guard recording.owner == .user else {
            ended[udid] = (recording.owner, result)
            return
        }
        if case .success(let finished) = result { onUserRecordingEnded?(udid, finished) }
    }

    /// Stops a recording outside the caller's task: a cancelled caller (the
    /// limit task, a cancelled agent call) must still let simctl finish the file.
    private static func finish(_ recording: any ScreenRecording) async -> Bool {
        await Task { await recording.stop() }.value
    }

    private func finished(_ recording: Running, written: Bool) -> Result<Finished, Failure> {
        guard written else { return .failure(.failed("simctl didn't write the video.")) }
        return .success(Finished(file: recording.file, seconds: now().timeIntervalSince(recording.startedAt)))
    }

    // MARK: Files

    /// Where agents' recordings go.
    static let agentRecordings = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Alas/Recordings", isDirectory: true)

    static func agentFile(udid: String, now: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return agentRecordings.appendingPathComponent("\(udid)-\(formatter.string(from: now)).mov")
    }

    /// Deletes recordings older than a week.
    static func pruneOldRecordings(in directory: URL = agentRecordings, now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > 7 * 24 * 3600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// `xcrun simctl io <udid> recordVideo`, which records until SIGINT.
@MainActor
final class LiveScreenRecording: ScreenRecording {
    private let process = Process()
    private var stopping = false
    var onExit: ((Bool) -> Void)?

    init(udid: String, file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec=h264", "--force", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let written = process.terminationStatus == 0
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.onExit?(written)
            }
        }
        try process.run()
    }

    func stop() async -> Bool {
        stopping = true
        guard process.isRunning else { return process.terminationStatus == 0 }
        process.interrupt()
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
