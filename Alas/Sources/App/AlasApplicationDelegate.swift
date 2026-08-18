import AppKit

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
    let markerURL: URL

    init(markerURL: URL = Paths.appSupportRoot.appendingPathComponent("launching")) {
        self.markerURL = markerURL
    }

    func begin() -> Bool {
        let previousLaunchDidNotFinish = FileManager.default.fileExists(atPath: markerURL.path)
        try? Paths.ensureDirectoryExists(markerURL.deletingLastPathComponent())
        _ = FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        return previousLaunchDidNotFinish
    }

    func finish() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
