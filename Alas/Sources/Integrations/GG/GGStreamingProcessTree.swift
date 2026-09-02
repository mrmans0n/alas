import Foundation

final class GGStreamingProcessTree: @unchecked Sendable {
    private let process: Process
    private let environmentMarker: String
    private let condition = NSCondition()
    private let refreshLock = NSLock()
    private var rootHasExited = false
    private var terminationInProgress = false
    private var terminationCompleted = false
    private var rootIdentity: ACPTerminal.DescendantKey?
    private var descendants: Set<ACPTerminal.DescendantKey> = []
    private var forkSources: [pid_t: DispatchSourceProcess] = [:]
    private var tracker: Task<Void, Never>?

    init(process: Process, environmentMarker: String) {
        self.process = process
        self.environmentMarker = environmentMarker
    }

    func start() {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        guard let rootIdentity = ACPTerminal.processKey(of: pid),
              ACPTerminal.currentlyMatching(Set([rootIdentity])).contains(rootIdentity)
        else { return }
        condition.lock()
        guard !rootHasExited, process.isRunning else {
            condition.unlock()
            return
        }
        self.rootIdentity = rootIdentity
        condition.unlock()
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
        if terminationCompleted {
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
        condition.broadcast()
        condition.unlock()
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
            stopTracking()
            finishTermination()
            return
        }
        var descendants = terminationTargets(rootPID: pid).union(environmentTargets(rootPID: pid))
        signalRootAndGroup(pid, signal: SIGTERM)
        signal(descendants, with: SIGTERM)

        let deadline = DispatchTime.now().uptimeNanoseconds + graceNanoseconds
        var rootExitObservedAt: UInt64?
        var scannedAfterRootExit = false
        var nextEnvironmentScanAt: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            refreshDescendants()
            var refreshed = terminationTargets(rootPID: pid)
            let now = DispatchTime.now().uptimeNanoseconds
            let rootHasExited = rootExitSnapshot()
            if rootHasExited, rootExitObservedAt == nil {
                rootExitObservedAt = now
            }
            if now >= nextEnvironmentScanAt {
                refreshed.formUnion(environmentTargets(rootPID: pid))
                nextEnvironmentScanAt = now + 100_000_000
                if let rootExitObservedAt,
                   now - rootExitObservedAt >= 50_000_000
                {
                    scannedAfterRootExit = true
                }
            }
            signal(refreshed.subtracting(descendants), with: SIGTERM)
            descendants.formUnion(refreshed)
            if rootHasExited,
               scannedAfterRootExit,
               ACPTerminal.currentlyMatching(descendants).isEmpty
            {
                break
            }
            usleep(20_000)
        }

        refreshDescendants()
        descendants.formUnion(terminationTargets(rootPID: pid))
        descendants.formUnion(environmentTargets(rootPID: pid))
        signalRootAndGroup(pid, signal: SIGKILL)
        signal(descendants, with: SIGKILL)
        let killSweepDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        repeat {
            refreshDescendants()
            descendants.formUnion(terminationTargets(rootPID: pid))
            descendants.formUnion(environmentTargets(rootPID: pid))
            let live = ACPTerminal.currentlyMatching(descendants)
            signal(live, with: SIGKILL)
            if live.isEmpty { break }
            usleep(20_000)
        } while DispatchTime.now().uptimeNanoseconds < killSweepDeadline
        stopTracking()
        if !rootExitSnapshot() {
            process.waitUntilExit()
        }
        finishTermination()
    }

    private func signalRootAndGroup(_ pid: pid_t, signal: Int32) {
        condition.lock()
        if !rootHasExited,
           let rootIdentity,
           rootIdentity.pid == pid,
           ACPTerminal.currentlyMatching(Set([rootIdentity])).contains(rootIdentity)
        {
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
        condition.unlock()
    }

    private func rootExitSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return rootHasExited
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
        let rootIdentity = rootIdentity
        let cached = descendants
        condition.unlock()
        let retained = ACPTerminal.currentlyMatching(cached)
        guard rootAlive, let rootIdentity, rootIdentity.pid == rootPID else { return retained }
        return retained.union(ACPTerminal.collectChildDescendants(of: rootIdentity))
    }

    private func environmentTargets(rootPID: pid_t) -> Set<ACPTerminal.DescendantKey> {
        let candidates = environmentPIDs().subtracting([rootPID])
        let identities = Set(candidates.compactMap(ACPTerminal.processKey(of:)))
        let confirmed = environmentPIDs()
        return Set(ACPTerminal.currentlyMatching(identities).filter { confirmed.contains($0.pid) })
    }

    private func environmentPIDs() -> Set<pid_t> {
        let scanner = Process()
        scanner.executableURL = URL(fileURLWithPath: "/bin/ps")
        scanner.arguments = ["eww", "-axo", "pid=,command="]
        let pipe = Pipe()
        scanner.standardOutput = pipe
        scanner.standardError = FileHandle.nullDevice
        do {
            try scanner.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            scanner.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return Set(output.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard fields.count == 2,
                      fields[1].contains(environmentMarker),
                      let pid = pid_t(fields[0]) else { return nil }
                return pid
            })
        } catch {
            return []
        }
    }

    private func refreshDescendants() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        condition.lock()
        let shouldStop = terminationCompleted
        let rootAlive = !rootHasExited
        let rootIdentity = rootIdentity
        let cached = descendants
        condition.unlock()
        guard !shouldStop else { return }

        let retained = ACPTerminal.currentlyMatching(cached)
        var live: Set<ACPTerminal.DescendantKey> = []
        if rootAlive, let rootIdentity {
            live.formUnion(ACPTerminal.collectChildDescendants(of: rootIdentity))
        }
        for descendant in retained {
            live.formUnion(ACPTerminal.collectChildDescendants(of: descendant))
        }
        let tracked = retained.union(live)
        condition.lock()
        guard !terminationCompleted else {
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
            let shouldCreate = forkSources[pid] == nil && !terminationCompleted
            condition.unlock()
            guard shouldCreate else { continue }

            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: [.fork, .exit],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                self?.processEvent(for: pid)
            }
            condition.lock()
            if forkSources[pid] == nil, !terminationCompleted {
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

    private func processEvent(for pid: pid_t) {
        condition.lock()
        guard let source = forkSources[pid] else {
            condition.unlock()
            return
        }
        let didExit = source.data.contains(.exit)
        if didExit {
            forkSources.removeValue(forKey: pid)
        }
        condition.unlock()
        refreshDescendants()
        if didExit { source.cancel() }
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
