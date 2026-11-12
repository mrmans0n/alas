import AlasCore
import Foundation
import Observation

/// Which app is in front on one simulator, from SpringBoard's log: the last
/// 10 minutes once, then a live `log stream`. Shared by the Logs tab and
/// pasting, so only the first question waits for the archive.
@MainActor
@Observable
final class SimulatorForegroundTracker {
    private(set) var current: String?
    private(set) var isReady = false

    @ObservationIgnored private let udid: String
    @ObservationIgnored private let fallback: (String) async -> String?
    @ObservationIgnored private let stream = SimulatorLogStream()
    @ObservationIgnored private var state = SimulatorForeground()
    /// Streamed lines that arrived while the archive was read.
    @ObservationIgnored private var early: [SimulatorLogLine] = []
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { stream.isRunning }

    init(udid: String, fallback: @escaping (String) async -> String?) {
        self.udid = udid
        self.fallback = fallback
    }

    func start() {
        isReady = false
        early = []
        stream.onAppend = { [weak self] lines in self?.received(lines) }
        stream.start(udid: udid, predicate: SimulatorForeground.predicate, levelArguments: [])
        Task {
            if let fromLog = await SimulatorControl.foregroundFromLog(udid: udid) {
                state = fromLog
                current = state.bundleID
            } else {
                state = SimulatorForeground()
                current = await fallback(udid)
            }
            isReady = true
            received(early)
            early = []
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
    }

    func stop() { stream.stop() }

    func bundleID() async -> String? {
        if !isReady { await withCheckedContinuation { readyWaiters.append($0) } }
        return current
    }

    private func received(_ lines: [SimulatorLogLine]) {
        guard isReady else {
            early += lines
            return
        }
        let before = state.bundleID
        for line in lines { state.apply(message: line.message) }
        if state.bundleID != before { current = state.bundleID }
    }
}
