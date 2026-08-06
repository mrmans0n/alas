import AppKit
import Foundation

enum RemotePollCadence {
    static let activeInterval: TimeInterval = 5
    static let inactiveInterval: TimeInterval = 45
    static let maxBackoff: TimeInterval = 300
    static let helperSafetyNetInterval: TimeInterval = 300

    static func nextDelay(succeeded: Bool, appActive: Bool, previous: TimeInterval) -> TimeInterval {
        succeeded ? (appActive ? activeInterval : inactiveInterval) : min(previous * 2, maxBackoff)
    }
}

struct RemoteProjectGitTickGate {
    private var isTicking = false
    private var hasPendingTick = false

    mutating func beginOrMarkPending() -> Bool {
        guard !isTicking else {
            hasPendingTick = true
            return false
        }
        isTicking = true
        return true
    }

    mutating func finishTick() -> Bool {
        guard hasPendingTick else {
            isTicking = false
            return false
        }
        hasPendingTick = false
        return true
    }
}

@MainActor
final class RemoteProjectGitWatcher {
    var onHeadChanged: (([URL: String]) -> Void)?
    var onRevisionChanged: (() -> Void)?
    var onTopologyChanged: (() -> Void)?

    private let projectPath: URL
    private let host: String?
    private var pollTask: Task<Void, Never>?
    private var helperSession: RemoteHelperWatchSession?
    private var lastEntries: [RemoteWorktreePollEntry]?
    private var lastSharedRefsSignature: String?
    private var tickGate = RemoteProjectGitTickGate()

    init(projectPath: URL) {
        self.projectPath = projectPath
        host = RemoteHostRegistry.shared.host(forPath: projectPath.path)
    }

    func start() {
        guard pollTask == nil, helperSession == nil else { return }
        if let host {
            let session = RemoteHelperWatchSession(
                host: host,
                root: projectPath.path,
                kinds: [.git]
            )
            session.onEvent = { [weak self] event in
                guard event.kind == .git else { return }
                Task { @MainActor in
                    self?.onRevisionChanged?()
                    _ = await self?.runTick()
                }
            }
            session.onAvailabilityChanged = { [weak self] _ in
                self?.restartPolling()
            }
            helperSession = session
            session.start()
        }
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var delay = RemotePollCadence.activeInterval
            while !Task.isCancelled {
                guard let self else { return }
                if helperSession?.isAvailable == true {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(RemotePollCadence.helperSafetyNetInterval * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    _ = await runTick()
                    continue
                }
                let succeeded = await runTick()
                helperSession?.retryIfNeeded()
                delay = RemotePollCadence.nextDelay(
                    succeeded: succeeded,
                    appActive: NSApp?.isActive ?? true,
                    previous: delay
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        helperSession?.stop()
        helperSession = nil
    }

    private func runTick() async -> Bool {
        guard tickGate.beginOrMarkPending() else { return true }
        var succeeded = true
        repeat {
            succeeded = await tickOnce()
        } while tickGate.finishTick()
        return succeeded
    }

    private func tickOnce() async -> Bool {
        let result = try? await Process.git(["worktree", "list", "--porcelain"], cwd: projectPath)
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            if let host { RemoteHostStatusStore.shared.reportConnectionFailure(host: host) }
            return false
        }
        if let host { RemoteHostStatusStore.shared.reportSuccess(host: host) }
        guard result.exitCode == 0 else { return true }

        let sharedRefsSignature = await pollSharedRefsSignature()
        let entries = RemoteWorktreePoll.parse(porcelain: result.stdout)
        defer {
            lastEntries = entries
            if let sharedRefsSignature {
                lastSharedRefsSignature = sharedRefsSignature
            }
        }
        var sharedRefsMoved = false
        if let sharedRefsSignature {
            sharedRefsMoved = lastSharedRefsSignature != nil && lastSharedRefsSignature != sharedRefsSignature
        }
        guard lastEntries != nil else {
            onTopologyChanged?()
            return true
        }
        guard let old = lastEntries, let delta = RemoteWorktreePoll.classify(old: old, new: entries) else {
            return true
        }
        if !delta.branchLabelsByPath.isEmpty {
            onHeadChanged?(Dictionary(uniqueKeysWithValues: delta.branchLabelsByPath.map {
                (URL(fileURLWithPath: $0.key), $0.value)
            }))
        }
        if delta.headMoved || sharedRefsMoved { onRevisionChanged?() }
        if delta.topologyChanged { onTopologyChanged?() }
        return true
    }

    private func pollSharedRefsSignature() async -> String? {
        let result = try? await Process.git(["show-ref", "--head"], cwd: projectPath)
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return nil
        }
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        return result.stdout
    }

    deinit { pollTask?.cancel() }
}
