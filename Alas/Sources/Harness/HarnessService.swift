import Foundation
import Observation

@Observable
final class HarnessService {
    let detector = HarnessDetector()
    let watcher: HookWatcher
    let notifications = NotificationService()

    /// session id → harness kind (set by detector)
    private(set) var harnessBySession: [String: HarnessKind] = [:]
    /// session id → harness state ("running" | "awaiting" | "done")
    private(set) var stateBySession: [String: String] = [:]

    var onClickThrough: ((String, String, String) -> Void)?

    init() {
        watcher = HookWatcher(dir: Paths.hookDir)
    }

    func start(stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?) {
        detector.onUpdate = { [weak self] sid, kind in
            guard let self else { return }
            if let kind {
                if self.harnessBySession[sid] != kind {
                    self.harnessBySession[sid] = kind
                    self.stateBySession[sid] = "running"
                }
            } else {
                if self.harnessBySession[sid] != nil {
                    self.harnessBySession.removeValue(forKey: sid)
                    self.stateBySession.removeValue(forKey: sid)
                }
            }
        }
        detector.start()

        notifications.setup { [weak self] p, w, s in
            self?.onClickThrough?(p, w, s)
        }

        watcher.onEvent = { [weak self] event in
            guard let self else { return }
            self.stateBySession[event.sessionId] = event.kind == "stop" ? "done" : "awaiting"
            if event.kind == "stop", let kind = self.harnessBySession[event.sessionId],
               let lookup = stateLookup(event.sessionId) {
                self.notifications.notifyHarnessFinished(
                    harness: kind, summary: event.summary,
                    projectId: lookup.projectId, worktreeId: lookup.worktreeId, sessionId: event.sessionId
                )
            }
        }
        watcher.start()
    }

    func stop() {
        detector.stop()
        watcher.stop()
    }
}
