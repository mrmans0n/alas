import AppKit
import CryptoKit
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
        let worktreePaths = ([projectPath] + entries.map { URL(fileURLWithPath: $0.path) })
            .reduce(into: [String: URL]()) { pathsByKey, path in
                pathsByKey[path.standardizedFileURL.path] = path
            }
            .sorted { $0.key < $1.key }
        let revisionConfigOutput = await pollRevisionConfigOutput(worktreePaths: worktreePaths)
        let customTopLevelRefsOutput = await pollCustomTopLevelRefsOutput(worktreePaths: worktreePaths)
        let privateRefsOutput = await pollPrivateRefsOutput(worktreePaths: worktreePaths)
        let reflogSignature = await pollReflogSignature()
        var pseudoRefCommits: [String: String] = [:]
        for (pathKey, path) in worktreePaths {
            guard let commits = await pollPseudoRefCommits(at: path) else { return nil }
            for (ref, commit) in commits {
                pseudoRefCommits["\(pathKey):\(ref)"] = commit
            }
        }
        return Self.sharedRefsSignature(
            showRefOutput: result.stdout,
            revisionConfigOutput: revisionConfigOutput,
            customTopLevelRefsOutput: customTopLevelRefsOutput,
            privateRefsOutput: privateRefsOutput,
            reflogSignature: reflogSignature,
            pseudoRefCommits: pseudoRefCommits
        )
    }

    private func pollRevisionConfigOutput(worktreePaths: [(key: String, value: URL)]) async -> String {
        var pathOutputs: [String: String] = [:]
        for (pathKey, path) in worktreePaths {
            let result = try? await Process.git(
                ["config", "--get-regexp", Self.revisionConfigPattern],
                cwd: path
            )
            guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                continue
            }
            guard result.exitCode == 0 || result.exitCode == 1 else { continue }
            pathOutputs[pathKey] = result.stdout
        }
        return Self.revisionConfigSignature(pathOutputs: pathOutputs)
    }

    private func pollCustomTopLevelRefsOutput(worktreePaths: [(key: String, value: URL)]) async -> String {
        var pathOutputs: [String: String] = [:]
        for (pathKey, path) in worktreePaths {
            if let host {
                let result = try? await RemoteExec.run(
                    host: host,
                    cwd: path.path,
                    command: Self.customTopLevelRefsCommand()
                )
                guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                    continue
                }
                guard result.exitCode == 0 else { continue }
                pathOutputs[pathKey] = result.stdout
            } else {
                pathOutputs[pathKey] = await Self.customTopLevelRefsOutput(at: path)
            }
        }
        return Self.topLevelRefsSignature(pathOutputs: pathOutputs)
    }

    private func pollPrivateRefsOutput(worktreePaths: [(key: String, value: URL)]) async -> String {
        var pathOutputs: [String: String] = [:]
        for (pathKey, path) in worktreePaths {
            let result = try? await Process.git(
                [
                    "for-each-ref",
                    "--format=%(objectname) %(refname)",
                    "refs/worktree",
                    "refs/bisect",
                    "refs/rewritten",
                ],
                cwd: path
            )
            guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                continue
            }
            guard result.exitCode == 0 else { continue }
            pathOutputs[pathKey] = result.stdout
        }
        return Self.privateRefsSignature(pathOutputs: pathOutputs)
    }

    private func pollReflogSignature() async -> String {
        let result: ProcessResult?
        if let host {
            result = try? await RemoteExec.run(
                host: host,
                cwd: projectPath.path,
                command: Self.reflogDigestCommand()
            )
        } else {
            result = try? await Process.git(
                ["reflog", "show", "--all", "--format=%H %gD"],
                cwd: projectPath
            )
        }
        guard let result, !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
            return ""
        }
        guard result.exitCode == 0 || result.exitCode == 1 else { return "" }
        guard host != nil else {
            return Self.reflogSignature(from: result.stdout)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        revisionConfigOutput: String = "",
        customTopLevelRefsOutput: String = "",
        privateRefsOutput: String = "",
        reflogSignature: String = "",
        pseudoRefCommits: [String: String]
    ) -> String {
        var signature = showRefOutput
        if !revisionConfigOutput.isEmpty {
            signature += "\nconfig:\(revisionConfigOutput)"
        }
        if !customTopLevelRefsOutput.isEmpty {
            signature += "\ntop-level-refs:\(customTopLevelRefsOutput)"
        }
        if !privateRefsOutput.isEmpty {
            signature += "\nprivate-refs:\(privateRefsOutput)"
        }
        if !reflogSignature.isEmpty {
            signature += "\nreflog:\(reflogSignature)"
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

    nonisolated static func revisionConfigSignature(pathOutputs: [String: String]) -> String {
        pathOutputs
            .flatMap { path, output in
                upstreamConfigSignature(from: output)
                    .split(whereSeparator: \.isNewline)
                    .map { "\(path):\($0)" }
            }
            .sorted()
            .joined(separator: "\n")
    }

    nonisolated static func topLevelRefsSignature(pathOutputs: [String: String]) -> String {
        pathOutputs
            .flatMap { path, output in
                output
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { "\(path):\($0)" }
            }
            .sorted()
            .joined(separator: "\n")
    }

    nonisolated static func privateRefsSignature(pathOutputs: [String: String]) -> String {
        pathOutputs
            .flatMap { path, output in
                output
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { "\(path):\($0)" }
            }
            .sorted()
            .joined(separator: "\n")
    }

    nonisolated static let revisionConfigPattern =
        #"^(branch\..*\.(remote|merge|pushremote)|remote\.pushdefault|push\.default|remote\..*\.push)$"#

    nonisolated static func customTopLevelRefsOutput(at worktreePath: URL) async -> String {
        guard let gitDirResult = try? await Process.git(
            ["rev-parse", "--absolute-git-dir"],
            cwd: worktreePath
        ),
            gitDirResult.exitCode == 0
        else { return "" }
        let gitDirPath = gitDirResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirPath.isEmpty else { return "" }
        let gitDir = URL(fileURLWithPath: gitDirPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: gitDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        else { return "" }
        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !nonRevisionTopLevelRefNames.contains(name),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            if name == "shallow" {
                return "shallow \(shallowSignature(from: contents))"
            }
            guard isTopLevelRevisionContent(contents) else { return nil }
            return "\(name) \(contents.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .sorted()
        .joined(separator: "\n")
    }

    nonisolated static func reflogSignature(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let digest = SHA256.hash(data: Data(output.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "entries=\(lines.count);sha=\(digest)"
    }

    nonisolated static func reflogDigestCommand() -> String {
        """
        status=0
        out=$(git reflog show --all --format='%H %gD') || status=$?
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
          exit "$status"
        fi
        if command -v shasum >/dev/null 2>&1; then
          digest=$(printf '%s\\n' "$out" | shasum -a 256 | awk '{print $1}')
        elif command -v sha256sum >/dev/null 2>&1; then
          digest=$(printf '%s\\n' "$out" | sha256sum | awk '{print $1}')
        else
          digest=$(printf '%s\\n' "$out" | cksum | awk '{print $1 ":" $2}')
        fi
        count=$(printf '%s\\n' "$out" | sed '/^$/d' | wc -l | awk '{print $1}')
        printf 'entries=%s;sha=%s\\n' "$count" "$digest"
        """
    }

    nonisolated static func customTopLevelRefsCommand() -> String {
        let ignored = nonRevisionTopLevelRefNames.sorted().joined(separator: "|")
        return """
        git_dir=$(git rev-parse --absolute-git-dir) || exit $?
        [ -d "$git_dir" ] || exit 0
        find "$git_dir" -maxdepth 1 -type f -print | while IFS= read -r path; do
          name=${path##*/}
          case "$name" in
            \(ignored)) continue ;;
          esac
          IFS= read -r line < "$path" || line=
          if [ "$name" = shallow ]; then
            out=$(cat "$path" 2>/dev/null || true)
            if command -v shasum >/dev/null 2>&1; then
              digest=$(printf '%s\\n' "$out" | shasum -a 256 | awk '{print $1}')
            elif command -v sha256sum >/dev/null 2>&1; then
              digest=$(printf '%s\\n' "$out" | sha256sum | awk '{print $1}')
            else
              digest=$(printf '%s\\n' "$out" | cksum | awk '{print $1 ":" $2}')
            fi
            count=$(printf '%s\\n' "$out" | sed '/^$/d' | wc -l | awk '{print $1}')
            printf 'shallow entries=%s;sha=%s\\n' "$count" "$digest"
            continue
          fi
          case "$line" in
            "ref: refs/"*) printf '%s %s\\n' "$name" "$line" ;;
            *) printf '%s' "$line" | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' && printf '%s %s\\n' "$name" "$line" ;;
          esac
        done | sort
        """
    }

    nonisolated static func isTopLevelRevisionContent(_ contents: String) -> Bool {
        let line = contents
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.hasPrefix("ref: refs/") {
            return true
        }
        return (line.count == 40 || line.count == 64) && line.allSatisfy(\.isHexDigit)
    }

    nonisolated static func shallowSignature(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let digest = SHA256.hash(data: Data(output.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "entries=\(lines.count);sha=\(digest)"
    }

    nonisolated static let nonRevisionTopLevelRefNames: Set<String> = [
        "branches",
        "COMMIT_EDITMSG",
        "commondir",
        "config",
        "config.worktree",
        "description",
        "gc.log",
        "gitdir",
        "hooks",
        "index",
        "info",
        "logs",
        "MERGE_MSG",
        "modules",
        "objects",
        "packed-refs",
        "refs",
        "SQUASH_MSG",
        "TAG_EDITMSG",
        "worktrees",
    ]

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
