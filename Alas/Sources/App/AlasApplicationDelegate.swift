import AppKit

@MainActor
final class AlasTerminationCoordinator {
    static let shared = AlasTerminationCoordinator()

    var flush: (() async -> Void)?

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
        // Synchronous and non-isolated: a detached Task would need to hop onto
        // the actor before running, and the process exits before that happens.
        try? FileManager.default.removeItem(at: RevisionSnapshotCache.shared.sessionDirectory)
    }
}
