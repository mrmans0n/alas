import Foundation

enum RunScriptCaptureLocation: Equatable, Sendable {
    case local(paths: RunScriptCapturePaths)
    case remote(host: String, paths: RunScriptCapturePaths)

    var paths: RunScriptCapturePaths {
        switch self {
        case let .local(paths), let .remote(_, paths):
            paths
        }
    }
}

struct RunScriptCompletion: Equatable, Sendable {
    let exitCode: Int32
    let completedAt: Date
    let transcript: Data?
    let truncated: Bool

    init(exitCode: Int32, completedAt: Date = Date(), transcript: Data?, truncated: Bool) {
        self.exitCode = exitCode
        self.completedAt = completedAt
        self.transcript = transcript
        self.truncated = truncated
    }
}

enum RunScriptCompletionMonitor {
    static let outputByteLimit = 1_048_576
    private static let outputBoundaryLookbehind = 4_096

    static func paths(runID: String, host: String?) throws -> RunScriptCaptureLocation {
        guard UUID(uuidString: runID) != nil else { throw MonitorError.invalidRunID }
        let file = runID.lowercased()
        if let host {
            return .remote(
                host: host,
                paths: RunScriptCapturePaths(
                    transcript: "~/.alas/run-transcripts/\(file).log",
                    completion: "~/.alas/run-transcripts/\(file).done"
                )
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Alas", isDirectory: true)
            .appendingPathComponent("run-transcripts", isDirectory: true)
        return .local(paths: RunScriptCapturePaths(
            transcript: directory.appendingPathComponent("\(file).log").path,
            completion: directory.appendingPathComponent("\(file).done").path
        ))
    }

    static func wait(for location: RunScriptCaptureLocation) async throws -> RunScriptCompletion {
        switch location {
        case let .local(paths):
            return try await waitLocal(paths: paths)
        case let .remote(host, paths):
            let result = try await RemoteExec.runData(
                host: host,
                cwd: nil,
                command: remoteWaitCommand(paths: paths, byteLimit: outputByteLimit),
                timeout: nil,
                pathPolicy: .inherited
            )
            guard !RemoteExec.isConnectionFailure(exitCode: result.exitCode) else {
                throw MonitorError.remoteConnectionFailed
            }
            guard result.exitCode == 0 else { throw MonitorError.remoteWaitFailed(result.exitCode) }
            return try parseRemotePayload(result.stdout)
        }
    }

    static func parseRemotePayload(_ data: Data) throws -> RunScriptCompletion {
        let marker = Data("ALAS_RUN_V1\t".utf8)
        var searchStart = data.startIndex
        while let range = data.range(of: marker, options: [], in: searchStart..<data.endIndex) {
            guard let newline = data[range.lowerBound...].firstIndex(of: 0x0A),
                  let header = String(data: data[range.lowerBound..<newline], encoding: .utf8),
                  let completion = parseRemoteHeader(header, body: data[data.index(after: newline)...])
            else {
                searchStart = data.index(after: range.lowerBound)
                continue
            }
            return completion
        }
        throw MonitorError.malformedRemotePayload
    }

    private static func parseRemoteHeader(_ header: String, body: Data.SubSequence) -> RunScriptCompletion? {
        let parts = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard (parts.count == 4 || parts.count == 5),
              parts[0] == "ALAS_RUN_V1",
              let exitCode = Int32(parts[1]),
              let captured = Int(parts[2]),
              let truncated = Int(parts[3]),
              (captured == 0 || captured == 1),
              (truncated == 0 || truncated == 1)
        else { return nil }
        let completedAt = parts.count == 5
            ? Date(timeIntervalSince1970: TimeInterval(String(parts[4])) ?? Date().timeIntervalSince1970)
            : Date()
        return RunScriptCompletion(
            exitCode: exitCode,
            completedAt: completedAt,
            transcript: captured == 1 ? Data(body) : nil,
            truncated: truncated == 1
        )
    }

    static func remoteWaitCommand(paths: RunScriptCapturePaths, byteLimit: Int) -> String {
        let transcript = remotePathShellLiteral(paths.transcript)
        let completion = remotePathShellLiteral(paths.completion)
        return """
        transcript=\(transcript)
        completion=\(completion)
        body="$completion.body"
        while [ ! -f "$completion" ]; do sleep 0.2; done
        set -- $(cat "$completion")
        exit_code=$1
        completed_at=${2:-$(date +%s)}
        captured=0
        truncated=0
        if [ "$exit_code" != 0 ] && [ -f "$transcript" ]; then
          if size=$(wc -c < "$transcript" | tr -d ' ') && tail -c \(byteLimit + outputBoundaryLookbehind) "$transcript" > "$body"; then
            captured=1
            if [ "${size:-0}" -gt \(byteLimit) ]; then truncated=1; fi
          fi
        fi
        printf 'ALAS_RUN_V1\\t%s\\t%s\\t%s\\t%s\\n' "$exit_code" "$captured" "$truncated" "$completed_at"
        if [ "$captured" = 1 ]; then cat "$body"; fi
        rm -f "$transcript" "$completion" "$completion.tmp" "$body" "$completion.status" || true
        """
    }

    static func cleanupStaleLocalFiles(now: Date = Date()) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Alas", isDirectory: true)
            .appendingPathComponent("run-transcripts", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in entries where ["log", "done", "tmp", "body", "status"].contains(entry.pathExtension) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private static func waitLocal(paths: RunScriptCapturePaths) async throws -> RunScriptCompletion {
        defer {
            try? FileManager.default.removeItem(atPath: paths.transcript)
            try? FileManager.default.removeItem(atPath: paths.completion)
            try? FileManager.default.removeItem(atPath: "\(paths.completion).tmp")
            try? FileManager.default.removeItem(atPath: "\(paths.completion).status")
        }
        while !FileManager.default.fileExists(atPath: paths.completion) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        let statusText = try String(contentsOfFile: paths.completion, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = statusText.split(whereSeparator: \.isWhitespace)
        guard let exitCodeText = parts.first,
              let exitCode = Int32(exitCodeText)
        else { throw MonitorError.malformedStatus }
        let completedAt = parts.dropFirst().first
            .flatMap { TimeInterval(String($0)) }
            .map { Date(timeIntervalSince1970: $0) } ?? Date()
        guard exitCode != 0 else {
            return RunScriptCompletion(exitCode: exitCode, completedAt: completedAt, transcript: nil, truncated: false)
        }
        guard FileManager.default.fileExists(atPath: paths.transcript) else {
            return RunScriptCompletion(exitCode: exitCode, completedAt: completedAt, transcript: nil, truncated: false)
        }
        let url = URL(fileURLWithPath: paths.transcript)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.transcript)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let readLimit = UInt64(outputByteLimit + outputBoundaryLookbehind)
            let offset = size > readLimit ? size - readLimit : 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return RunScriptCompletion(
                exitCode: exitCode,
                completedAt: completedAt,
                transcript: try handle.readToEnd() ?? Data(),
                truncated: offset > 0
            )
        } catch {
            return RunScriptCompletion(exitCode: exitCode, completedAt: completedAt, transcript: nil, truncated: false)
        }
    }

    private static func remotePathShellLiteral(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return SSHCommand.shellQuote(path) }
        return "\"$HOME/\(path.dropFirst(2).doubleQuotedShellEscaped)\""
    }

    enum MonitorError: Error, Equatable {
        case invalidRunID
        case malformedStatus
        case malformedRemotePayload
        case remoteConnectionFailed
        case remoteWaitFailed(Int32)
    }
}

private extension StringProtocol {
    var doubleQuotedShellEscaped: String {
        String(self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
