import AppKit
import Darwin

@MainActor
final class AlasTerminationCoordinator {
    static let shared = AlasTerminationCoordinator()

    var flush: (() async -> Void)?
    var finish: (() -> Void)?

    private init() {}
}

@MainActor
final class AlasApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AlasTerminationCoordinator.shared.finish?()
        guard !terminationInProgress, let flush = AlasTerminationCoordinator.shared.flush else {
            return .terminateNow
        }
        terminationInProgress = true
        Task {
            await flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AlasTerminationCoordinator.shared.finish?()
        // Synchronous and non-isolated: a detached Task would need to hop onto
        // the actor before running, and the process exits before that happens.
        try? FileManager.default.removeItem(at: RevisionSnapshotCache.shared.sessionDirectory)
    }
}

struct StartupRecovery {
    let markerDirectory: URL
    let markerURL: URL
    private let processID: Int32
    private let isProcessAlive: (Int32) -> Bool
    private let processStartTime: (Int32) -> TimeInterval?

    init(
        markerDirectory: URL = Paths.appSupportRoot,
        processID: Int32 = getpid(),
        isProcessAlive: @escaping (Int32) -> Bool = StartupRecovery.processIsAlive,
        processStartTime: @escaping (Int32) -> TimeInterval? = StartupRecovery.processStartTime
    ) {
        self.markerDirectory = markerDirectory
        self.processID = processID
        self.isProcessAlive = isProcessAlive
        self.processStartTime = processStartTime
        let startTime = processStartTime(processID).map { Int64($0 * 1_000_000) } ?? 0
        markerURL = markerDirectory.appendingPathComponent("launching-\(processID)-\(startTime)-\(UUID().uuidString)")
    }

    func begin() -> Bool {
        try? Paths.ensureDirectoryExists(markerDirectory)
        let previousLaunchDidNotFinish = removeAbandonedMarkers()
        _ = FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        return previousLaunchDidNotFinish
    }

    func finish() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private func removeAbandonedMarkers() -> Bool {
        guard let markerNames = try? FileManager.default.contentsOfDirectory(atPath: markerDirectory.path) else {
            return false
        }
        var foundAbandonedMarker = false
        for markerName in markerNames {
            let marker = markerDirectory.appendingPathComponent(markerName)
            if markerName == "launching" {
                try? FileManager.default.removeItem(at: marker)
                foundAbandonedMarker = true
                continue
            }
            let components = markerName.split(separator: "-", maxSplits: 3)
            guard components.count == 4,
                  components[0] == "launching",
                  let markerPID = Int32(components[1]),
                  let markerStartTime = Int64(components[2]) else { continue }
            if isProcessAlive(markerPID),
               let currentStartTime = processStartTime(markerPID).map({ Int64($0 * 1_000_000) }),
               currentStartTime == markerStartTime {
                continue
            }
            try? FileManager.default.removeItem(at: marker)
            foundAbandonedMarker = true
        }
        return foundAbandonedMarker
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processStartTime(_ pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
            }
        }
        guard read == Int32(size) else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }
}
