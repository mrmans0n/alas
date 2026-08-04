import Foundation
import Darwin

final class HarnessDetector {
    /// Called every poll with the latest detected kind for a session (or nil).
    var onUpdate: ((String, HarnessKind?) -> Void)?

    typealias PidProvider = () -> pid_t?
    private var providers: [String: PidProvider] = [:]

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.nlopez.alas.harness-detector")

    func register(sessionId: String, pidProvider: @escaping PidProvider) {
        queue.async { self.providers[sessionId] = pidProvider }
    }

    func unregister(sessionId: String) {
        queue.async { self.providers.removeValue(forKey: sessionId) }
    }

    func isRegistered(sessionId: String) -> Bool {
        queue.sync { providers[sessionId] != nil }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        self.timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let snapshot = providers   // copy under queue
        for (sid, provider) in snapshot {
            let pid = provider() ?? 0
            let kind: HarnessKind? = pid > 0 ? Self.matchKind(pid: pid) : nil
            DispatchQueue.main.async { self.onUpdate?(sid, kind) }
        }
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
