import Foundation

final class GGStreamingProcessTree: @unchecked Sendable {
    private let process: Process
    private let condition = NSCondition()
    private var rootHasExited = false
    private var terminationInProgress = false
    private var terminationCompleted = false

    init(process: Process) {
        self.process = process
    }

    func start() {
        _ = setpgid(process.processIdentifier, process.processIdentifier)
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
        guard !terminationCompleted, !rootHasExited else {
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
        let descendants = Set(ACPTerminal.collectChildDescendants(of: pid))
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

    private func finishTermination() {
        condition.lock()
        terminationInProgress = false
        terminationCompleted = true
        condition.broadcast()
        condition.unlock()
    }
}
