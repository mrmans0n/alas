import Foundation

final class GGStreamingProcessTree: @unchecked Sendable {
    private let process: Process
    private let condition = NSCondition()
    private let refreshLock = NSLock()
    private var rootHasExited = false
    private var terminationInProgress = false
    private var terminationCompleted = false
    private var descendants: Set<ACPTerminal.DescendantKey> = []
    private var forkSources: [pid_t: DispatchSourceProcess] = [:]
    private var tracker: Task<Void, Never>?

    init(process: Process) {
        self.process = process
    }

    func start() {
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)
        observeForks(from: [pid])
        refreshDescendants()
        let tracker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.refreshDescendants()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        condition.lock()
        if rootHasExited {
            condition.unlock()
            tracker.cancel()
        } else {
            self.tracker = tracker
            condition.unlock()
        }
    }

    func rootDidExit() {
        condition.lock()
        rootHasExited = true
        let tracker = tracker
        self.tracker = nil
        let sources = Array(forkSources.values)
        forkSources.removeAll()
        condition.broadcast()
        condition.unlock()
        tracker?.cancel()
        for source in sources { source.cancel() }
    }

    func terminateAndWait(graceNanoseconds: UInt64 = 2_000_000_000) {
        condition.lock()
        while terminationInProgress {
            condition.wait()
        }
        guard !terminationCompleted else {
            condition.unlock()
            return
        }
        terminationInProgress = true
        condition.unlock()

        let pid = process.processIdentifier
        guard pid > 0 else {
            finishTermination()
            return
        }
        stopTracking()
        let descendants = terminationTargets(rootPID: pid)
        signalRootAndGroup(pid, signal: SIGTERM)
        signal(descendants, with: SIGTERM)

        let deadline = DispatchTime.now().uptimeNanoseconds + graceNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !process.isRunning, ACPTerminal.currentlyMatching(descendants).isEmpty {
                break
            }
            usleep(20_000)
        }

        signalRootAndGroup(pid, signal: SIGKILL)
        signal(descendants, with: SIGKILL)
        if process.isRunning {
            process.waitUntilExit()
        }
        finishTermination()
    }

    func waitForActiveTermination() {
        condition.lock()
        while terminationInProgress {
            condition.wait()
        }
        condition.unlock()
    }

    private func signalRootAndGroup(_ pid: pid_t, signal: Int32) {
        condition.lock()
        if !rootHasExited, process.isRunning {
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
        condition.unlock()
    }

    private func signal(_ descendants: Set<ACPTerminal.DescendantKey>, with signal: Int32) {
        for descendant in ACPTerminal.currentlyMatching(descendants) {
            _ = Darwin.kill(descendant.pid, signal)
        }
    }

    private func terminationTargets(rootPID: pid_t) -> Set<ACPTerminal.DescendantKey> {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        condition.lock()
        let rootAlive = !rootHasExited
        let cached = descendants
        condition.unlock()
        let retained = ACPTerminal.currentlyMatching(cached)
        guard rootAlive else { return retained }
        return retained.union(ACPTerminal.collectChildDescendants(of: rootPID))
    }

    private func refreshDescendants() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        condition.lock()
        let shouldStop = rootHasExited || terminationInProgress
        let cached = descendants
        condition.unlock()
        guard !shouldStop, process.isRunning else { return }

        let live = Set(ACPTerminal.collectChildDescendants(of: process.processIdentifier))
        let retained = ACPTerminal.currentlyMatching(cached)
        let tracked = retained.union(live)
        condition.lock()
        guard !rootHasExited, !terminationInProgress else {
            condition.unlock()
            return
        }
        descendants = tracked
        condition.unlock()
        observeForks(from: tracked.map(\.pid))
    }

    private func observeForks(from pids: [pid_t]) {
        for pid in pids where pid > 0 {
            condition.lock()
            let shouldCreate = forkSources[pid] == nil && !rootHasExited && !terminationInProgress
            condition.unlock()
            guard shouldCreate else { continue }

            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .fork,
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                self?.refreshDescendants()
            }
            condition.lock()
            if forkSources[pid] == nil, !rootHasExited, !terminationInProgress {
                forkSources[pid] = source
                condition.unlock()
                source.resume()
            } else {
                condition.unlock()
                source.resume()
                source.cancel()
            }
        }
    }

    private func stopTracking() {
        condition.lock()
        let tracker = tracker
        self.tracker = nil
        let sources = Array(forkSources.values)
        forkSources.removeAll()
        condition.unlock()
        tracker?.cancel()
        for source in sources { source.cancel() }
    }

    private func finishTermination() {
        condition.lock()
        terminationInProgress = false
        terminationCompleted = true
        condition.broadcast()
        condition.unlock()
    }
}
