import Foundation
import AlasPlatform

/// Resolves foreground processes in the SSH host's PID namespace.
public enum RemoteTerminalHarness {
    private struct ProcessRow {
        let pid: Int
        let parent: Int
        let group: Int
        let foregroundGroup: Int
        let executable: String

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
            let path = columns[4]
            let deletedSuffix = " (deleted)"
            self.executable = String(path.hasSuffix(deletedSuffix) ? path.dropLast(deletedSuffix.count) : path)
        }
    }

    static func detect(sessions: [ZmxSessionInfo], processTable: String) -> [String: HarnessKind] {
        let rows = processTable.split(separator: "\n").compactMap(ProcessRow.init)
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byParent = Dictionary(grouping: rows, by: \.parent)
        func foregroundChildren(of row: ProcessRow) -> [ProcessRow] {
            byParent[row.pid, default: []].filter {
                $0.group == row.group && $0.foregroundGroup == row.group
            }
        }

        var agents: [String: HarnessKind] = [:]
        for session in sessions {
            guard let shellPID = session.pid, let shell = byPID[shellPID],
                  shell.foregroundGroup > 0, let foreground = byPID[shell.foregroundGroup],
                  foreground.group == shell.foregroundGroup else { continue }
            if let kind = matchExecutable(foreground.executable) {
                agents[session.name] = kind
                continue
            }

            let candidates = Set(foregroundChildren(of: foreground).flatMap { child -> [HarnessKind] in
                if let kind = matchExecutable(child.executable) { return [kind] }
                // A noninteractive zmx shell can share its foreground group
                // with a launcher and the native executable it starts.
                guard foreground.pid == shellPID else { return [] }
                return foregroundChildren(of: child).compactMap { matchExecutable($0.executable) }
            })
            if candidates.count == 1 { agents[session.name] = candidates.first }
        }
        return agents
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

    /// One batch SSH request per host. On Linux, comm can truncate executable
    /// names, so resolve the executable link for foreground jobs when available.
    public static func observe(host: String) async throws -> [String: HarnessKind] {
        let marker = "__ALAS_REMOTE_PROCESS_TABLE__"
        let list = RemoteTerminalScript.zmxBatchCommand(["ls"])
        let command = #"""
        sessions=$( (\#(list)) ) || exit 1
        printf '%s\n%s\n' "$sessions" '\#(marker)'
        [ -n "$sessions" ] || exit 0
        processes=$(LC_ALL=C ps -axww -o pid= -o ppid= -o pgid= -o tpgid= -o comm=) || exit 1
        printf '%s\n' "$processes" | {
            while read -r pid parent group foreground executable; do
                if [ "$group" = "$foreground" ] && [ "$group" -gt 0 ] && [ -L "/proc/$pid/exe" ]; then
                    resolved=$(readlink "/proc/$pid/exe" 2>/dev/null) && executable="$resolved"
                fi
                printf '%s %s %s %s %s\n' "$pid" "$parent" "$group" "$foreground" "$executable"
            done
        }
        """#
        let result = try await RemoteExec.run(host: host, cwd: nil, command: command, timeout: 5)
        guard result.exitCode == 0,
              let boundary = result.stdout.range(of: "\n\(marker)\n") else {
            throw CocoaError(.fileReadUnknown)
        }
        let sessions = ZmxClient.parseSessionInfos(String(result.stdout[..<boundary.lowerBound]))
        return detect(sessions: sessions, processTable: String(result.stdout[boundary.upperBound...]))
    }
}

/// Polls each SSH host once, regardless of how many persistent panes it owns.
@MainActor
public final class RemoteTerminalHarnessMonitor {
    public init() {}

    private var namesByHost: [String: [String: String]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public func register(sessionID: String, host: String, name: String, harness: HarnessService) {
        namesByHost[host, default: [:]][sessionID] = name
        guard tasks[host] == nil else { return }
        tasks[host] = Task { [weak self, weak harness] in
            while !Task.isCancelled {
                let detected = try? await RemoteTerminalHarness.observe(host: host)
                guard !Task.isCancelled, let names = self?.namesByHost[host], let harness else { return }
                for (sessionID, name) in names {
                    harness.recordHarnessDetection(sessionId: sessionID, kind: detected?[name])
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func unregister(sessionID: String, host: String, harness: HarnessService) {
        guard namesByHost[host]?.removeValue(forKey: sessionID) != nil else { return }
        harness.recordHarnessDetection(sessionId: sessionID, kind: nil)
        if namesByHost[host]?.isEmpty == true {
            namesByHost.removeValue(forKey: host)
            tasks.removeValue(forKey: host)?.cancel()
        }
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
