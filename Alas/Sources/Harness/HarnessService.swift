import Foundation
import Observation

@Observable
final class HarnessService {
    let detector = HarnessDetector()
    let watcher: HookWatcher
    let notifications = NotificationService()

    /// session id → last-known harness kind for this session. NEVER cleared
    /// when the detector reports "no longer running" because the stop hook
    /// often races process exit: harness exits → detector reports nil →
    /// THEN the hook file lands and we'd have nothing to attribute it to.
    /// Preserve the kind through the session so notifications fire reliably.
    private(set) var harnessBySession: [String: HarnessKind] = [:]
    /// session id → live state ("running" | "awaiting" | "done"). Cleared
    /// only when the detector reports nil AND we're not awaiting a hook
    /// outcome, so the tab badge dot disappears naturally.
    private(set) var stateBySession: [String: String] = [:]

    var onClickThrough: ((String, String, String) -> Void)?

    init() {
        watcher = HookWatcher(dir: Paths.hookDir)
    }

    func start(
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        shouldNotifyOnAwaiting: @escaping () -> Bool = { true }
    ) {
        detector.onUpdate = { [weak self] sid, kind in
            guard let self else { return }
            self.recordHarnessDetection(sessionId: sid, kind: kind)
        }
        detector.start()

        notifications.setup { [weak self] p, w, s in
            self?.onClickThrough?(p, w, s)
        }

        watcher.onEvent = { [weak self] event in
            self?.handleHookEvent(
                event,
                stateLookup: stateLookup,
                shouldNotifyOnAwaiting: shouldNotifyOnAwaiting
            )
        }
        watcher.start()
    }

    func recordHarnessDetection(sessionId: String, kind: HarnessKind?) {
        if let kind {
            if harnessBySession[sessionId] != kind {
                harnessBySession[sessionId] = kind
                stateBySession[sessionId] = "running"
            }
        } else {
            // Process exited but the stop-hook event may still be in
            // flight. Drop the running-state badge so the UI reflects
            // "not actively running", but KEEP harnessBySession so the
            // upcoming hook can attribute its kind.
            stateBySession.removeValue(forKey: sessionId)
        }
    }

    func handleHookEvent(
        _ event: HookEvent,
        stateLookup: (String) -> (projectId: String, worktreeId: String)?,
        shouldNotifyOnAwaiting: () -> Bool
    ) {
        let previousState = stateBySession[event.sessionId]
        stateBySession[event.sessionId] = event.kind == "stop" ? "done" : "awaiting"

        if event.kind == "awaiting" {
            if previousState != "awaiting", shouldNotifyOnAwaiting(),
               let kind = harnessBySession[event.sessionId],
               let lookup = stateLookup(event.sessionId) {
                notifications.notifyHarnessAwaiting(
                    harness: kind,
                    projectId: lookup.projectId,
                    worktreeId: lookup.worktreeId,
                    sessionId: event.sessionId
                )
            }
            return
        }

        if event.kind == "stop", let kind = harnessBySession[event.sessionId],
           let lookup = stateLookup(event.sessionId) {
            notifications.notifyHarnessFinished(
                harness: kind, summary: event.summary,
                projectId: lookup.projectId, worktreeId: lookup.worktreeId, sessionId: event.sessionId
            )
        }
    }

    func stop() {
        detector.stop()
        watcher.stop()
    }

    /// Drop all per-session harness state. Call when the terminal session is
    /// closed so we don't leak entries forever in `harnessBySession`.
    func forgetSession(_ sessionId: String) {
        harnessBySession.removeValue(forKey: sessionId)
        stateBySession.removeValue(forKey: sessionId)
    }
}
