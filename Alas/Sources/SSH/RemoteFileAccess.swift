import Foundation

enum RemoteReadResult: Equatable {
    case file(data: Data, mtime: Date)
    case missing
    case directory
    case unreadable(String)
}

enum RemoteFileAccessError: Error, Equatable {
    case connectionFailed(String)
    case writeFailed(String)
}

/// Should a remote save proceed given the buffer's baseline mtime and the
/// file's current remote mtime? A strictly newer remote mtime means someone
/// else wrote the file since we loaded it.
enum RemoteSaveGate {
    enum Decision: Equatable {
        case proceed
        case conflict
        case targetDeleted
    }

    static func decision(originalMtime: Date?, remoteMtime: Date?) -> Decision {
        guard let originalMtime else { return .proceed }
        guard let remoteMtime else { return .targetDeleted }
        return remoteMtime > originalMtime ? .conflict : .proceed
    }
}

/// File I/O over ssh, one round trip per operation. Scripts are POSIX
/// portable (GNU and BSD remotes); `stat` flavors are chained instead of
/// OS-gated. Exit-code contract for reads: 3 = directory, 4 = missing.
enum RemoteFileAccess {
    /// Chained GNU-then-BSD mtime probe, reused across scripts.
    private static let statMtime = "stat -c %Y -- \"$f\" 2>/dev/null || stat -f %m -- \"$f\""

    static func readScript(path: String) -> String {
        "f=\(SSHCommand.shellQuote(path)); "
            + "[ -d \"$f\" ] && exit 3; "
            + "[ -e \"$f\" ] || exit 4; "
            + "(\(statMtime)); "
            + "cat -- \"$f\""
    }

    /// Payload is `<epoch-seconds>\\n<raw bytes>`; the body is binary-safe.
    static func parseReadPayload(_ data: Data) -> (mtime: Date, contents: Data)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard let header = String(data: data[data.startIndex..<newline], encoding: .utf8),
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces))
        else { return nil }
        let body = data[data.index(after: newline)...]
        return (Date(timeIntervalSince1970: seconds), Data(body))
    }

    static func read(host: String, path: String) async throws -> RemoteReadResult {
        let result = try await RemoteExec.runData(
            host: host,
            cwd: nil,
            command: readScript(path: path)
        )
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        switch result.exitCode {
        case 3:
            return .directory
        case 4:
            return .missing
        case 0:
            guard let parsed = parseReadPayload(result.stdout) else {
                return .unreadable("unexpected read payload")
            }
            return .file(data: parsed.contents, mtime: parsed.mtime)
        default:
            return .unreadable(result.stderr)
        }
    }

    /// Atomically writes content while preserving the mode of an existing
    /// file. New files use the remote process's umask. Prints the post-save
    /// mtime on stdout.
    static func writeScript(path: String) -> String {
        "f=\(SSHCommand.shellQuote(path)); t=\"$f.alas-$$.tmp\"; "
            + "if [ -f \"$f\" ]; then cp -p -- \"$f\" \"$t\" || exit 3; fi; "
            + "cat > \"$t\" || { rm -f -- \"$t\"; exit 4; }; "
            + "mv -- \"$t\" \"$f\" || { rm -f -- \"$t\"; exit 5; }; "
            + statMtime
    }

    static func write(host: String, path: String, content: String) async throws -> Date {
        let invocation = RemoteExec.invocation(
            host: host,
            cwd: nil,
            command: writeScript(path: path)
        )
        let result = try await Process.run(
            invocation.executable,
            args: invocation.args,
            stdin: content,
            timeout: 60
        )
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0,
              let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw RemoteFileAccessError.writeFailed(result.stderr)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Returns nil when the target does not exist. Throws only for an ssh
    /// connection failure.
    static func mtime(host: String, path: String) async throws -> Date? {
        let command = "f=\(SSHCommand.shellQuote(path)); \(statMtime)"
        let result = try await RemoteExec.run(host: host, cwd: nil, command: command)
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0,
              let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
