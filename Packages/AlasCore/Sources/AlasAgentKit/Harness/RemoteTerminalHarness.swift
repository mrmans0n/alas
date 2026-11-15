import Foundation
import AlasModel
import AlasPlatform

/// Resolves foreground processes in the SSH host's PID namespace.
public enum RemoteTerminalHarness {
    private struct ProcessRow {
        let pid: Int
        let parent: Int
        let group: Int
        let foregroundGroup: Int
        /// The process name, then the resolved executable link when the host sends one.
        let executables: [String]

        var kind: HarnessKind? { executables.lazy.compactMap(RemoteTerminalHarness.matchExecutable).first }

        init?(_ line: Substring) {
            let columns = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard columns.count == 5, let pid = Int(columns[0]), pid > 0,
                  let parent = Int(columns[1]), let group = Int(columns[2]),
                  let foregroundGroup = Int(columns[3]) else { return nil }
            self.pid = pid
            self.parent = parent
            self.group = group
            self.foregroundGroup = foregroundGroup
            // Linux appends this suffix when an update unlinks the running binary.
            let deletedSuffix = " (deleted)"
            self.executables = columns[4].split(separator: "\t").map { path in
                String(path.hasSuffix(deletedSuffix) ? path.dropLast(deletedSuffix.count) : path)
            }
        }
    }

    struct Snapshot: Sendable {
        var agents: [String: HarnessKind] = [:]
        var hooks: [String: AgentHookEvent] = [:]
    }

    static func detect(sessions: [ZmxSessionInfo], processTable: String) -> [String: HarnessKind] {
        snapshot(sessions: sessions, processTable: processTable).agents
    }

    static func snapshot(
        sessions: [ZmxSessionInfo], processTable: String,
        hookOutput: String = "", namesByID: [String: String] = [:]
    ) -> Snapshot {
        let rows = processTable.split(separator: "\n").compactMap(ProcessRow.init)
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byParent = Dictionary(grouping: rows, by: \.parent)
        func foregroundChildren(of row: ProcessRow) -> [ProcessRow] {
            byParent[row.pid, default: []].filter {
                $0.group == row.group && $0.foregroundGroup == row.group
            }
        }

        var result = Snapshot()
        var groupsByName: [String: Int] = [:]
        for session in sessions {
            guard let shellPID = session.pid, let shell = byPID[shellPID],
                  shell.foregroundGroup > 0, let foreground = byPID[shell.foregroundGroup],
                  foreground.group == shell.foregroundGroup else { continue }
            groupsByName[session.name] = foreground.group
            if let kind = foreground.kind {
                result.agents[session.name] = kind
                continue
            }

            let candidates = Set(foregroundChildren(of: foreground).flatMap { child -> [HarnessKind] in
                if let kind = child.kind { return [kind] }
                // A noninteractive zmx shell can share its foreground group
                // with a launcher and the native executable it starts.
                guard foreground.pid == shellPID else { return [] }
                return foregroundChildren(of: child).compactMap(\.kind)
            })
            if candidates.count == 1 { result.agents[session.name] = candidates.first }
        }
        for line in hookOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].utf8.count <= 8192 else { continue }
            let id = String(fields[0])
            guard let name = namesByID[id], let group = groupsByName[name],
                  let hook = try? AgentHookEvent.decode(from: Data(fields[1].utf8)),
                  hook.version == 1, hook.sessionId == id,
                  let pid = hook.pid, let process = byPID[Int(pid)],
                  process.group == group, process.foregroundGroup == group,
                  result.agents[name]?.asAgentKind == hook.agent else { continue }
            switch hook.event {
            case .attached, .busy, .awaitingInput, .permissionRequest, .idle:
                result.hooks[id] = hook
            case .backgroundStarted, .backgroundEnded, .detached:
                break
            }
        }
        return result
    }

    private static func matchExecutable(_ path: String) -> HarnessKind? {
        let executable = path as NSString
        let basename = executable.lastPathComponent
        if let kind = HarnessDetector.matchKind(processName: basename) { return kind }

        // A native Claude install can resolve to a version-numbered binary.
        if executable.deletingLastPathComponent.hasSuffix("/.local/share/claude/versions"),
           basename.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil {
            return .claudeCode
        }
        return nil
    }

    /// Keeps the monitored sessions' zmx records. Reads `$sessions`, sets `$selected` and `$pids`.
    static func selectSessionsScript(names: Set<String>) -> String {
        let quoted = SSHCommand.shellQuote(names.sorted().joined(separator: "\n"))
        return #"""
        selected=$(printf '%s\n' "$sessions" | ALAS_NAMES=\#(quoted) LC_ALL=C awk -F '\t' '
            BEGIN { n = split(ENVIRON["ALAS_NAMES"], list, "\n"); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
            { sub(/^[ \t\r]+/, ""); sub(/[ \t\r]+$/, "") }
            { for (i = 1; i <= NF; i++) if ($i ~ /^name=/ && (substr($i, 6) in wanted)) { print; break } }
        ')
        pids=$(printf '%s\n' "$selected" | LC_ALL=C awk -F '\t' '
            { for (i = 1; i <= NF; i++) if ($i ~ /^pid=[0-9]+$/) print substr($i, 5) }
        ')
        """#
    }

    /// Keeps the process rows detection reads for `$pids`: each shell, its foreground
    /// group leader, that group's foreground children and, under a noninteractive
    /// shell, their children. Reads `$processes`, sets `$rows`.
    static let selectRowsScript = #"""
    rows=$(printf '%s\n' "$processes" | ALAS_PIDS="$pids" LC_ALL=C awk '
        BEGIN { n = split(ENVIRON["ALAS_PIDS"], roots, "\n") }
        {
            if ($1 !~ /^[0-9]+$/ || NF < 5) next
            pid = $1 + 0
            parent[pid] = $2 + 0; group[pid] = $3 + 0; fore[pid] = $4 + 0
            sub(/^[ \t]*[0-9-]+[ \t]+[0-9-]+[ \t]+[0-9-]+[ \t]+[0-9-]+[ \t]+/, "")
            exe[pid] = $0
        }
        END {
            for (i = 1; i <= n; i++) {
                shell = roots[i] + 0
                if (!(shell in group)) continue
                leader = fore[shell]
                if (leader <= 0 || !(leader in group) || group[leader] != leader) continue
                keep[shell] = 1; keep[leader] = 1
                for (child in parent) {
                    if (parent[child] != leader || group[child] != leader || fore[child] != leader) continue
                    keep[child + 0] = 1
                    if (leader != shell) continue
                    for (grandchild in parent)
                        if (parent[grandchild] == child + 0 && group[grandchild] == leader && fore[grandchild] == leader)
                            keep[grandchild + 0] = 1
                }
            }
            for (pid in keep) print pid, parent[pid], group[pid], fore[pid], exe[pid]
        }
    ')
    """#

    /// One batch SSH request per host. The host takes a single process snapshot and
    /// returns only the monitored sessions, the rows their detection needs, and
    /// their hook mailboxes. On Linux, comm can truncate executable names, so
    /// those rows also carry the resolved executable link after a tab. comm stays
    /// first: an interpreter-backed agent is recognizable only by its name.
    static func observeSnapshot(host: String, namesByID: [String: String]) async throws -> Snapshot {
        guard !namesByID.isEmpty else { return Snapshot() }
        let marker = "__ALAS_REMOTE_PROCESS_TABLE__"
        let hookMarker = "__ALAS_REMOTE_HOOK_MAILBOXES__"
        let mailboxReads = namesByID.keys.sorted().compactMap { id -> String? in
            guard let path = RemoteTerminalScript.hookMailboxPath(sessionID: id) else { return nil }
            return #"if [ -f "\#(path)" ]; then printf '%s\t' \#(SSHCommand.shellQuote(id)); head -c 8193 "\#(path)"; printf '\n'; fi"#
        }.joined(separator: "\n")
        let list = RemoteTerminalScript.zmxBatchCommand(["ls"])
        let command = #"""
        sessions=$( (\#(list)) ) || exit 1
        \#(selectSessionsScript(names: Set(namesByID.values)))
        printf '%s\n%s\n' "$selected" '\#(marker)'
        [ -n "$selected" ] || exit 0
        processes=$(LC_ALL=C ps -axww -o pid= -o ppid= -o pgid= -o tpgid= -o comm=) || exit 1
        \#(selectRowsScript)
        printf '%s\n' "$rows" | {
            while read -r pid parent group foreground executable; do
                resolved=
                if [ "$group" = "$foreground" ] && [ "$group" -gt 0 ] && [ -L "/proc/$pid/exe" ]; then
                    resolved=$(readlink "/proc/$pid/exe" 2>/dev/null) || resolved=
                fi
                printf '%s %s %s %s %s\t%s\n' "$pid" "$parent" "$group" "$foreground" "$executable" "$resolved"
            done
        }
        printf '%s\n' '\#(hookMarker)'
        \#(mailboxReads)
        """#
        let result = try await RemoteExec.run(host: host, cwd: nil, command: command, timeout: 5)
        guard result.exitCode == 0,
              let boundary = result.stdout.range(of: "\n\(marker)\n") else {
            throw CocoaError(.fileReadUnknown)
        }
        let sessions = ZmxClient.parseSessionInfos(String(result.stdout[..<boundary.lowerBound]))
        let tail = result.stdout[boundary.upperBound...]
        let sections = tail.components(separatedBy: hookMarker + "\n")
        return snapshot(
            sessions: sessions, processTable: sections[0],
            hookOutput: sections.count == 2 ? sections[1] : "", namesByID: namesByID
        )
    }
}

/// Polls each SSH host once, regardless of how many persistent panes it owns.
@MainActor
public final class RemoteTerminalHarnessMonitor {
    public init() {}

    private var namesByHost: [String: [String: String]] = [:]
    private var lastHookByID: [String: AgentHookEvent] = [:]
    private var foregroundHookIDs: Set<String> = []
    /// Panes a poll has answered for. A mailbox already there on the first answer is restored state.
    private var observedIDs: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]

    public func register(sessionID: String, host: String, name: String, harness: HarnessService) {
        namesByHost[host, default: [:]][sessionID] = name
        guard tasks[host] == nil else { return }
        tasks[host] = Task { [weak self, weak harness] in
            while !Task.isCancelled {
                guard let subscribed = self?.namesByHost[host] else { return }
                let snapshot = try? await RemoteTerminalHarness.observeSnapshot(host: host, namesByID: subscribed)
                guard !Task.isCancelled, let self, let names = self.namesByHost[host], let harness else { return }
                self.apply(snapshot, asked: subscribed, current: names, harness: harness)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Applies one poll of the panes in `asked`; `snapshot` is nil when it failed.
    func apply(
        _ snapshot: RemoteTerminalHarness.Snapshot?, asked: [String: String], current: [String: String],
        harness: HarnessService
    ) {
        // A failed poll says nothing about the panes, so they keep their last state.
        guard let snapshot else { return }
        // A pane registered during the poll waits for one that asked about it.
        for (sessionID, name) in current where asked[sessionID] == name {
            let hook = snapshot.hooks[sessionID]
            let prior = lastHookByID[sessionID]
            if hook == nil, foregroundHookIDs.remove(sessionID) != nil {
                harness.forgetSession(sessionID)
            }
            harness.recordHarnessDetection(sessionId: sessionID, kind: snapshot.agents[name])
            if let hook {
                let returnedToForeground = foregroundHookIDs.insert(sessionID).inserted
                if observedIDs.contains(sessionID), hook != prior {
                    harness.socketServer.onEvent?(hook)
                } else if returnedToForeground, let state = Self.restoredState(hook.event) {
                    // Restore an existing mailbox without replaying its side effects.
                    harness.setExternalActivity(
                        sessionId: sessionID, agent: hook.agent, state: state, body: hook.body, isSnapshot: true
                    )
                }
                // A temporary loss of foreground eligibility must not erase this event.
                lastHookByID[sessionID] = hook
            }
            observedIDs.insert(sessionID)
        }
    }

    private static func restoredState(_ event: ActivityEvent) -> ActivityState? {
        switch event {
        case .attached, .busy: .busy
        case .awaitingInput: .awaitingInput
        case .permissionRequest: .permissionRequest
        case .idle: .idle
        case .backgroundStarted, .backgroundEnded, .detached: nil
        }
    }

    public func unregister(sessionID: String, harness: HarnessService) {
        guard let host = namesByHost.first(where: { $0.value[sessionID] != nil })?.key else { return }
        namesByHost[host]?.removeValue(forKey: sessionID)
        observedIDs.remove(sessionID)
        foregroundHookIDs.remove(sessionID)
        if lastHookByID.removeValue(forKey: sessionID) != nil {
            harness.forgetSession(sessionID)
        } else {
            harness.recordHarnessDetection(sessionId: sessionID, kind: nil)
        }
        if namesByHost[host]?.isEmpty == true {
            namesByHost.removeValue(forKey: host)
            tasks.removeValue(forKey: host)?.cancel()
        }
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
