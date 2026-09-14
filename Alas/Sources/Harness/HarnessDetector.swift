import Foundation
import Darwin

/// Polls the foreground process of every registered terminal session and
/// reports which AI harness (if any) is running in it.
///
/// `@unchecked Sendable` rather than `@MainActor`: the poll runs on a private
/// serial queue on purpose, because `proc_pidpath` is a syscall per session
/// per second and must not land on the main thread. Registration, however,
/// happens from the main actor (`AppState`), so the object is genuinely
/// shared across threads.
///
/// Soundness rests on two invariants:
///
/// 1. **All mutable state is lock-confined.** `_providers`, `_timer` and
///    `_onUpdate` are private and are only read or written inside `lock`.
///    `queue` is now only the timer's target queue — it no longer doubles as
///    the confinement domain for `_providers`, which was unenforceable from
///    the type's public API.
/// 2. **Registered providers and `onUpdate` are snapshotted, then called with
///    the lock released.** Providers are deliberately not `Sendable`: they
///    read a terminal session's foreground pid and are called off-main, which
///    is exactly the behaviour this type has always had. `onUpdate` is
///    deliberately not `Sendable` either — it is wired from
///    `HarnessService.start` on the main actor and closes over main-actor
///    state — so it is only ever invoked from `deliverUpdate`, which runs
///    inside `DispatchQueue.main.async`.
final class HarnessDetector: @unchecked Sendable {
    typealias PidProvider = () -> pid_t?
    /// Called every poll with the latest detected kind for a session (or nil).
    /// Invoked on the main queue — see the type's invariants.
    typealias UpdateHandler = (String, HarnessKind?) -> Void

    /// Guards every mutable field below. See the invariants on the type.
    private let lock = NSLock()
    private var _providers: [String: PidProvider] = [:]
    private var _timer: DispatchSourceTimer?
    private var _onUpdate: UpdateHandler?

    private let queue = DispatchQueue(label: "io.nlopez.alas.harness-detector")

    var onUpdate: UpdateHandler? {
        get { lock.withLock { _onUpdate } }
        set { lock.withLock { _onUpdate = newValue } }
    }

    func register(sessionId: String, pidProvider: @escaping PidProvider) {
        lock.withLock { _providers[sessionId] = pidProvider }
    }

    func unregister(sessionId: String) {
        lock.withLock { _ = _providers.removeValue(forKey: sessionId) }
    }

    func isRegistered(sessionId: String) -> Bool {
        lock.withLock { _providers[sessionId] != nil }
    }

    func foregroundPid(sessionId: String) -> pid_t? {
        // Snapshot under the lock, call outside it: the provider reads
        // terminal-session state and must never run while the lock is held.
        let provider = lock.withLock { _providers[sessionId] }
        return provider?()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        lock.withLock { _timer = t }
    }

    func stop() {
        let cancelled = lock.withLock { () -> DispatchSourceTimer? in
            let current = _timer
            _timer = nil
            return current
        }
        cancelled?.cancel()
    }

    /// Runs on `queue`.
    private func tick() {
        let snapshot = lock.withLock { _providers }
        for (sid, provider) in snapshot {
            let pid = provider() ?? 0
            let kind: HarnessKind? = pid > 0 ? Self.matchKind(pid: pid) : nil
            DispatchQueue.main.async { [self] in deliverUpdate(sessionId: sid, kind: kind) }
        }
    }

    /// Invoked only from `DispatchQueue.main.async`. Snapshots the handler
    /// under the lock, then calls it with the lock released.
    private func deliverUpdate(sessionId: String, kind: HarnessKind?) {
        let handler = lock.withLock { _onUpdate }
        handler?(sessionId, kind)
    }

    static func matchKind(processName: String) -> HarnessKind? {
        for kind in HarnessKind.allCases {
            for name in kind.processNames {
                if processName == name || (name.count > 2 && processName.hasPrefix(name + "-")) {
                    return kind
                }
            }
        }
        return nil
    }

    /// Resolve the executable basename of `pid` and try to match it.
    static func matchKind(pid: pid_t) -> HarnessKind? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096; the constant is a C macro
        // not exported by the Swift Darwin overlay, so we use the literal value.
        let maxPathSize = 4 * Int(MAXPATHLEN)   // 4096
        var pathBuf = [CChar](repeating: 0, count: maxPathSize)
        let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard len > 0 else { return nil }
        let path = String(cString: pathBuf)
        let basename = (path as NSString).lastPathComponent
        return matchKind(processName: basename)
    }
}
