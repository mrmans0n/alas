import AlasCore
import Foundation
import Observation

/// A running `log stream` on one simulator: its parsed lines, newest last.
@MainActor
@Observable
final class SimulatorLogStream {
    static let lineLimit = 5000

    private(set) var lines: [SimulatorLogLine] = []
    /// Lines dropped to keep `lineLimit`.
    private(set) var dropped = 0
    private(set) var isRunning = false
    /// Why the stream stopped on its own, if it did.
    private(set) var stopReason: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0
    /// Called with each batch of new lines.
    @ObservationIgnored var onAppend: (([SimulatorLogLine]) -> Void)?

    func start(udid: String, query: SimulatorLogQuery) {
        start(udid: udid, predicate: query.predicate, levelArguments: query.streamArguments)
    }

    func start(udid: String, predicate: String?, levelArguments: [String]) {
        stop()
        generation += 1
        let current = generation
        stopReason = nil
        var args = ["simctl", "spawn", udid, "log", "stream", "--style", "ndjson"] + levelArguments
        if let predicate { args += ["--predicate", predicate] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let parsed = reader.lines(from: handle.availableData).compactMap(SimulatorLogLine.parse)
            guard !parsed.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.append(parsed)
            }
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.isRunning = false
                self.process = nil
                self.stopReason = "Logging stopped (simctl exited with status \(finished.terminationStatus))."
            }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            stopReason = error.localizedDescription
        }
    }

    func stop() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        dropped = 0
    }

    private func append(_ new: [SimulatorLogLine]) {
        lines.append(contentsOf: new)
        let excess = lines.count - Self.lineLimit
        if excess > 0 {
            lines.removeFirst(excess)
            dropped += excess
        }
        onAppend?(new)
    }
}

/// Splits a byte stream into lines across reads.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func lines(from chunk: Data) -> [Data] {
        lock.withLock {
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}
