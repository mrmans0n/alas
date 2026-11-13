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
    enum Owner: Hashable, Sendable {
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
        /// Written, but saving it failed; the video is still at the URL.
        case notSaved(URL, String)
    }

    private struct Running {
        let owner: Owner
        let file: URL
        let startedAt: Date
        let recording: any ScreenRecording
        let limit: Task<Void, Never>?
    }

    /// Each recording of yours once its video is written, however it ended
    /// (Stop, a shutdown, quitting), to be saved.
    /// Returns where it was saved; throwing leaves the video where it is.
    @ObservationIgnored var onUserRecordingEnded: ((String, Finished) throws -> URL)?
    /// Recordings whose video simctl is still writing, so quitting can wait for them.
    @ObservationIgnored private var finishing: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var running: [String: Running] = [:]
    /// Recordings that ended by themselves, per simulator and owner, kept for
    /// the owner's `stop`; a task, so a stop during simctl's finishing waits for it.
    @ObservationIgnored private var ended: [String: [Owner: Task<Result<Finished, Failure>, Never>]] = [:]
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
        // An ended recording this owner never collected gives way to its new one; others' stay.
        ended[udid]?[owner] = nil
        let recording: any ScreenRecording
        do {
            recording = try startRecording(udid, file)
        } catch {
            throw .failed(error.localizedDescription)
        }
        let startedAt = now()
        // Weak: the recording holds this closure, so a strong capture would keep it, and its process, alive.
        recording.onExit = { [weak self, weak recording] written in
            guard let recording else { return }
            self?.endedByItself(udid: udid, recording: recording, written: written)
        }
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
            return try await finalize(current, udid: udid, at: now()).value.get()
        }
        if let kept = ended[udid]?[owner] {
            ended[udid]?[owner] = nil
            return try await kept.value.get()
        }
        throw .notRecording
    }

    /// The simulator shut down: its recording ends, kept for its owner.
    func simulatorStopped(udid: String) async {
        guard let current = running[udid] else { return }
        await stopByItself(udid: udid, recording: current.recording)
    }

    /// Alas is quitting: every recording ends and its video is written, also
    /// ones already stopping; yours are saved. Without this, simctl would record on.
    func stopAll() async {
        for (udid, current) in running {
            await stopByItself(udid: udid, recording: current.recording)
        }
        for task in Array(finishing.values) { await task.value }
    }

    private func stopByItself(udid: String, recording: any ScreenRecording) async {
        guard let current = running[udid], current.recording === recording else { return }
        running[udid] = nil
        // This may run inside the limit task, which the cancel below reaches;
        // the finishing task is a new one, so the cancel doesn't reach it.
        current.limit?.cancel()
        let task = finalize(current, udid: udid, at: now())
        keep(current, udid: udid, result: task)
        _ = await task.value
    }

    private func endedByItself(udid: String, recording: any ScreenRecording, written: Bool) {
        guard let current = running[udid], current.recording === recording else { return }
        running[udid] = nil
        current.limit?.cancel()
        let result = save(Self.finished(current, written: written, at: now()), of: current, udid: udid)
        keep(current, udid: udid, result: Task { result })
    }

    /// Saves your finished recording; an agent's stays where it was written.
    private func save(_ result: Result<Finished, Failure>, of recording: Running, udid: String) -> Result<Finished, Failure> {
        guard recording.owner == .user, case .success(let finished) = result, let save = onUserRecordingEnded else { return result }
        do {
            return .success(Finished(file: try save(udid, finished), seconds: finished.seconds))
        } catch {
            return .failure(.notSaved(finished.file, error.localizedDescription))
        }
    }

    /// Keeps an agent's ended recording for its next stop, also while it is
    /// still finishing. Yours is handed on instead, once written.
    private func keep(_ recording: Running, udid: String, result: Task<Result<Finished, Failure>, Never>) {
        guard recording.owner != .user else { return }
        ended[udid, default: [:]][recording.owner] = result
    }

    /// Ends a recording in its own task, since a cancelled caller (the limit
    /// task, a cancelled agent call) must still let simctl finish the file, and
    /// tracks it until written. Yours is then handed on to be saved.
    private func finalize(_ current: Running, udid: String, at end: Date) -> Task<Result<Finished, Failure>, Never> {
        let id = ObjectIdentifier(current.recording)
        let task = Task { [weak self] () -> Result<Finished, Failure> in
            let written = Self.finished(current, written: await current.recording.stop(), at: end)
            let result = self?.save(written, of: current, udid: udid) ?? written
            self?.finishing[id] = nil
            return result
        }
        finishing[id] = Task { _ = await task.value }
        return task
    }

    private static func finished(_ recording: Running, written: Bool, at end: Date) -> Result<Finished, Failure> {
        guard written else { return .failure(.failed("simctl didn't write the video.")) }
        return .success(Finished(file: recording.file, seconds: end.timeIntervalSince(recording.startedAt)))
    }

    // MARK: Files

    /// Where agents' recordings go.
    static let agentRecordings = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Alas/Recordings", isDirectory: true)

    static func agentFile(udid: String, now: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // The suffix keeps two recordings started in the same second apart: simctl overwrites (--force).
        let suffix = UUID().uuidString.prefix(8)
        return agentRecordings.appendingPathComponent("\(udid)-\(formatter.string(from: now))-\(suffix).mov")
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
