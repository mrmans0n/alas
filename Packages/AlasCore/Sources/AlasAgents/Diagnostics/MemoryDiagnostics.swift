#if DEBUG
import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP
import AlasSessions

/// Aggregates per-subsystem memory accounting across all attached
/// `ACPSessionManager`s. Pull-model: the snapshot walks live state when
/// asked; nothing tracked per mutation.
///
/// The tick timer (debug builds only) calls `snapshot()` periodically and
/// emits the one-line summary via `os.Logger`. The `latest` publisher feeds
/// the debug "Memory report…" window.
@MainActor
public final class MemoryDiagnostics: ChangeTracking {
    nonisolated(unsafe) public let willChange = ChangeSignal<Void>()
    @Tracked public private(set) var latest: MemorySnapshot?

    private var managers: [String: ACPSessionManager] = [:]
    private var timer: Timer?
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "mem")

    public func attach(manager: ACPSessionManager) {
        managers[manager.worktreeId] = manager
    }

    public func detach(worktreeId: String) {
        managers.removeValue(forKey: worktreeId)
    }

    public func snapshot() -> MemorySnapshot {
        var perSession: [MemorySnapshot.PerSession] = []
        var transcriptBytes: UInt64 = 0
        var markdownCacheBytes: UInt64 = 0
        var terminalBytes: UInt64 = 0
        var sessionCount = 0
        var runnerCount = 0
        for (worktreeId, manager) in managers {
            runnerCount += manager.runnerCountForDiagnostics
            for session in manager.sessions.values {
                let tx = session.transcriptByteEstimate()
                let md = session.markdownCacheByteEstimate()
                let term = session.terminalHost.retainedByteEstimate
                transcriptBytes &+= tx
                markdownCacheBytes &+= md
                terminalBytes &+= term
                sessionCount += 1
                perSession.append(.init(
                    sessionId: session.id,
                    worktreeId: worktreeId,
                    transcriptBytes: tx,
                    markdownCacheBytes: md,
                    messageCount: session.transcript.messages.count,
                    attached: Self.isAttached(state: session.agentState)))
            }
        }
        return MemorySnapshot(
            timestamp: Date(),
            physFootprint: ProcessMemoryProbe.physFootprint(),
            transcriptBytes: transcriptBytes,
            markdownCacheBytes: markdownCacheBytes,
            terminalBytes: terminalBytes,
            sessionCount: sessionCount,
            runnerCount: runnerCount,
            perSession: perSession)
    }

    /// Start a repeating tick. Pass `nil` to stop. Safe to call multiple times.
    public func startTicker(interval: TimeInterval = 30) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let snap = snapshot()
        latest = snap
        logger.log("\(snap.oneLineLog(), privacy: .public)")
    }

    /// Force an immediate sample and publish. Used by the debug
    /// "Refresh now" button. Does NOT emit an os_log line, so manual
    /// refreshes don't pollute the tick stream.
    public func refreshNow() {
        latest = snapshot()
    }

    /// True when a runner is live (or being spawned) — these sessions
    /// pin themselves into `ACPSessionManager.sessions` until the agent
    /// process exits or detaches.
    private static func isAttached(state: ACPSession.AgentState) -> Bool {
        switch state {
        case .spawning, .ready: return true
        case .idle, .disconnected, .failed: return false
        }
    }

    public init() {}
}
#endif
