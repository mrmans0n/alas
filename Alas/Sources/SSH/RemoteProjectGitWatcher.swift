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

        let entries = RemoteWorktreePoll.parse(porcelain: result.stdout)
        let sharedRefsSignature = await pollSharedRefsSignature(entries: entries)
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
        let events = Self.events(old: lastEntries, new: entries, sharedRefsMoved: sharedRefsMoved)
        if !events.branchLabelsByPath.isEmpty {
            onHeadChanged?(Dictionary(uniqueKeysWithValues: events.branchLabelsByPath.map {
                (URL(fileURLWithPath: $0.key), $0.value)
            }))
        }
        if events.revisionChanged { onRevisionChanged?() }
        if events.topologyChanged { onTopologyChanged?() }
        return true
    }

    nonisolated static func events(
        old: [RemoteWorktreePollEntry]?,
        new: [RemoteWorktreePollEntry],
        sharedRefsMoved: Bool
    ) -> RemoteProjectGitWatcherEvents {
        guard let old else {
            return RemoteProjectGitWatcherEvents(
                branchLabelsByPath: [:],
                revisionChanged: sharedRefsMoved,
                topologyChanged: true
            )
        }
        guard let delta = RemoteWorktreePoll.classify(old: old, new: new) else {
            return RemoteProjectGitWatcherEvents(
                branchLabelsByPath: [:],
                revisionChanged: sharedRefsMoved,
                topologyChanged: false
            )
        }
        return RemoteProjectGitWatcherEvents(
            branchLabelsByPath: delta.branchLabelsByPath,
            revisionChanged: delta.headMoved || sharedRefsMoved,
            topologyChanged: delta.topologyChanged
        )
    }

    private func pollSharedRefsSignature(entries: [RemoteWorktreePollEntry]) async -> String? {
        let result = try? await Process.git(["show-ref", "--head"], cwd: projectPath)
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return nil
        }
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        let upstreamConfigOutput = await pollUpstreamConfigOutput()
        let reflogOutput = await pollReflogOutput()
        var pseudoRefCommits: [String: String] = [:]
        let worktreePaths = ([projectPath] + entries.map { URL(fileURLWithPath: $0.path) })
            .reduce(into: [String: URL]()) { pathsByKey, path in
                pathsByKey[path.standardizedFileURL.path] = path
            }
            .sorted { $0.key < $1.key }
        for (pathKey, path) in worktreePaths {
            guard let commits = await pollPseudoRefCommits(at: path) else { return nil }
            for (ref, commit) in commits {
                pseudoRefCommits["\(pathKey):\(ref)"] = commit
            }
        }
        return Self.sharedRefsSignature(
            showRefOutput: result.stdout,
            upstreamConfigOutput: upstreamConfigOutput,
            reflogOutput: reflogOutput,
            pseudoRefCommits: pseudoRefCommits
        )
    }

    private func pollUpstreamConfigOutput() async -> String {
        let result = try? await Process.git(
            ["config", "--get-regexp", #"^(branch\..*\.(remote|merge|pushRemote)|remote\.pushDefault|push\.default)$"#],
            cwd: projectPath
        )
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return ""
        }
        guard result.exitCode == 0 || result.exitCode == 1 else { return "" }
        return Self.upstreamConfigSignature(from: result.stdout)
    }

    private func pollReflogOutput() async -> String {
        let result = try? await Process.git(
            ["reflog", "show", "--all", "--max-count=256", "--format=%H %gD"],
            cwd: projectPath
        )
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return ""
        }
        guard result.exitCode == 0 || result.exitCode == 1 else { return "" }
        return result.stdout
    }

    private func pollPseudoRefCommits(at path: URL) async -> [String: String]? {
        let refs = Self.revisionPseudoRefs
        let stdin = refs.map { "\($0)^{commit}" }.joined(separator: "\n") + "\n"
        let result = try? await Process.git(
            ["cat-file", "--batch-check=%(objectname)"],
            cwd: path,
            stdin: stdin
        )
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return nil
        }
        guard result.exitCode == 0 else { return Dictionary(uniqueKeysWithValues: refs.map { ($0, "") }) }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        var commits: [String: String] = [:]
        for (idx, ref) in refs.enumerated() {
            guard lines.indices.contains(idx) else {
                commits[ref] = ""
                continue
            }
            let line = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            commits[ref] = line.contains(" missing") ? "" : line
        }
        return commits
    }

    deinit { pollTask?.cancel() }

    nonisolated static func sharedRefsSignature(
        showRefOutput: String,
        upstreamConfigOutput: String = "",
        reflogOutput: String = "",
        pseudoRefCommits: [String: String]
    ) -> String {
        var signature = showRefOutput
        if !upstreamConfigOutput.isEmpty {
            signature += "\nconfig:\(upstreamConfigOutput)"
        }
        if !reflogOutput.isEmpty {
            signature += "\nreflog:\(reflogOutput)"
        }
        for key in pseudoRefCommits.keys.sorted() {
            signature += "\n\(key):\(pseudoRefCommits[key] ?? "")"
        }
        return signature
    }

    nonisolated static func upstreamConfigSignature(from output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "\n")
    }

    nonisolated static let revisionPseudoRefs = [
        "AUTO_MERGE",
        "CHERRY_PICK_HEAD",
        "FETCH_HEAD",
        "MERGE_HEAD",
        "ORIG_HEAD",
        "REBASE_HEAD",
        "REVERT_HEAD",
    ]
}

struct RemoteProjectGitWatcherEvents: Equatable {
    var branchLabelsByPath: [String: String]
    var revisionChanged: Bool
    var topologyChanged: Bool
}
