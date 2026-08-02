import Foundation
import OSLog

enum RemoteReadResult: Equatable {
    case file(data: Data, mtime: Date)
    case missing
    case directory
    case symlink
    case unreadable(String)
}

enum RemoteFileAccessError: Error, Equatable {
    case connectionFailed(String)
    case writeFailed(String)
    case saveConflict(RemoteSaveConflict)
}

enum RemotePathExistence: Equatable {
    case exists
    case missing
    case unknown
}

enum RemoteSaveConflict: Equatable {
    case changed
    case deleted
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

    static func requiresContentCheck(originalMtime: Date?, remoteMtime: Date?) -> Bool {
        guard let originalMtime, let remoteMtime else { return false }
        return remoteMtime <= originalMtime
    }
}

enum RemoteOperationTiming {
    private static let logger = Logger(subsystem: "app.alas", category: "RemoteOperations")

    static func log(_ operation: String, host: String, transport: String, startedAt: CFAbsoluteTime) {
        let milliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        logger.debug(
            "\(operation, privacy: .public) host=\(host, privacy: .public) transport=\(transport, privacy: .public) duration_ms=\(milliseconds, format: .fixed(precision: 1))"
        )
    }
}

/// Remote file I/O prefers the persistent helper channel. The POSIX ssh
/// scripts remain the compatibility path for hosts without a usable helper.
enum RemoteFileAccess {
    /// Chained GNU-then-BSD mtime probe, reused across scripts.
    private static let statMtime = "stat -c %Y -- \"$f\" 2>/dev/null || stat -f %m \"$f\""

    static func readScript(path: String) -> String {
        "f=\(SSHCommand.shellQuote(path)); "
            + "[ -L \"$f\" ] && exit 5; "
            + "[ -d \"$f\" ] && exit 3; "
            + "[ -e \"$f\" ] || exit 4; "
            + "(\(statMtime)); "
            + "cat \"$f\""
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
        if await helperSupportsRead(host: host) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.read(path: path)
                RemoteOperationTiming.log("fs/read", host: host, transport: "helper", startedAt: startedAt)
                return readResult(from: result)
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/read", host: host, transport: "helper", startedAt: startedAt)
                if case .jsonrpc(let rpcError) = error {
                    return .unreadable(rpcError.message)
                }
                return .unreadable(String(describing: error))
            } catch {
                RemoteOperationTiming.log("fs/read", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }
        return try await readViaExec(host: host, path: path)
    }

    static func readResult(from result: RemoteHelperFSReadResult) -> RemoteReadResult {
        switch result.kind {
        case "missing":
            return .missing
        case "directory":
            return .directory
        case "symlink":
            return .symlink
        case "unreadable":
            return .unreadable(result.detail ?? "remote helper could not read the file")
        case "file", nil:
            let data = result.contentBase64.flatMap { Data(base64Encoded: $0) }
                ?? result.content.map { Data($0.utf8) }
            guard let data, let seconds = result.mtime else {
                return .unreadable("unexpected helper read payload")
            }
            return .file(data: data, mtime: Date(timeIntervalSince1970: seconds))
        default:
            return .unreadable("unexpected helper read kind")
        }
    }

    private static func readViaExec(host: String, path: String) async throws -> RemoteReadResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/read", host: host, transport: "exec", startedAt: startedAt) }
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
        case 5:
            return .symlink
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
            + "[ -L \"$f\" ] && exit 6; "
            + "[ -d \"$f\" ] && exit 7; "
            + "mode=\"\"; "
            + "if [ -f \"$f\" ]; then "
            + "mode=$(stat -c %a -- \"$f\" 2>/dev/null || stat -f %Lp \"$f\") || exit 3; "
            + "cp -p \"$f\" \"$t\" || exit 3; "
            + "chmod u+w \"$t\" || { rm -f \"$t\"; exit 3; }; "
            + "fi; "
            + "cat > \"$t\" || { rm -f \"$t\"; exit 4; }; "
            + "[ -z \"$mode\" ] || chmod \"$mode\" \"$t\" || { rm -f \"$t\"; exit 4; }; "
            + "mv \"$t\" \"$f\" || { rm -f \"$t\"; exit 5; }; "
            + statMtime
    }

    static func write(
        host: String,
        path: String,
        content: String,
        expectedMtime: Date? = nil,
        expectedContent: String? = nil
    ) async throws -> Date {
        if await helperSupportsWrite(host: host, expectedContent: expectedContent) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.write(
                    path: path,
                    content: content,
                    expectedMtime: expectedMtime?.timeIntervalSince1970,
                    expectedContent: expectedContent
                )
                RemoteOperationTiming.log("fs/write", host: host, transport: "helper", startedAt: startedAt)
                guard let seconds = result.mtime else {
                    throw RemoteFileAccessError.writeFailed("unexpected helper write payload")
                }
                return Date(timeIntervalSince1970: seconds)
            } catch let error as RemoteHelperClientError {
                RemoteOperationTiming.log(
                    "fs/write",
                    host: host,
                    transport: error.shouldFallbackToRemoteExec ? "helper-fallback" : "helper",
                    startedAt: startedAt
                )
                if case .jsonrpc(let rpcError) = error, rpcError.code == -32030 {
                    throw RemoteFileAccessError.saveConflict(
                        rpcError.message.contains("missing") ? .deleted : .changed
                    )
                }
                guard error.shouldFallbackToRemoteExec else {
                    throw RemoteFileAccessError.writeFailed(String(describing: error))
                }
            } catch let error as RemoteFileAccessError {
                throw error
            } catch {
                RemoteOperationTiming.log("fs/write", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        if let expectedMtime {
            let remoteMtime = try await mtimeViaExec(host: host, path: path)
            switch RemoteSaveGate.decision(originalMtime: expectedMtime, remoteMtime: remoteMtime) {
            case .conflict:
                throw RemoteFileAccessError.saveConflict(.changed)
            case .targetDeleted:
                throw RemoteFileAccessError.saveConflict(.deleted)
            case .proceed:
                break
            }
            if RemoteSaveGate.requiresContentCheck(originalMtime: expectedMtime, remoteMtime: remoteMtime),
               let expectedContent {
                guard case let .file(data, _) = try await readViaExec(host: host, path: path),
                      String(data: data, encoding: .utf8) == expectedContent
                else {
                    throw RemoteFileAccessError.saveConflict(.changed)
                }
            }
        }
        return try await writeViaExec(host: host, path: path, content: content)
    }

    private static func writeViaExec(host: String, path: String, content: String) async throws -> Date {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/write", host: host, transport: "exec", startedAt: startedAt) }
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
        if await helperIsInstalled(host: host) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.stat(paths: [path])
                RemoteOperationTiming.log("fs/stat", host: host, transport: "helper", startedAt: startedAt)
                guard let entry = result.entries.first, entry.exists else { return nil }
                return entry.mtime.map(Date.init(timeIntervalSince1970:))
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/stat", host: host, transport: "helper", startedAt: startedAt)
                return nil
            } catch {
                RemoteOperationTiming.log("fs/stat", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }
        return try await mtimeViaExec(host: host, path: path)
    }

    static func existence(host: String, path: String) async -> RemotePathExistence {
        if await helperIsInstalled(host: host) {
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.stat(paths: [path])
                guard let entry = result.entries.first else { return .unknown }
                return entry.exists ? .exists : .missing
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                return .unknown
            } catch {
                // Fall through to the exec probe when the helper transport is unavailable.
            }
        }
        let quotedPath = SSHCommand.shellQuote(path)
        let command = "p=\(quotedPath); if [ -e \"$p\" ] || [ -L \"$p\" ]; then printf exists; else printf missing; fi"
        guard let result = try? await RemoteExec.run(host: host, cwd: nil, command: command),
              !RemoteExec.isConnectionFailure(exitCode: result.exitCode),
              result.exitCode == 0
        else { return .unknown }
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "exists": return .exists
        case "missing": return .missing
        default: return .unknown
        }
    }

    private static func mtimeViaExec(host: String, path: String) async throws -> Date? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/stat", host: host, transport: "exec", startedAt: startedAt) }
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

    private static func helperIsInstalled(host: String) async -> Bool {
        await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake != nil
    }

    private static func helperSupportsRead(host: String) async -> Bool {
        await RemoteHostCapabilityStore.shared.capabilities(for: host)?
            .helperHandshake?
            .supportsFilesystemV04Contract == true
    }

    private static func helperSupportsWrite(host: String, expectedContent: String?) async -> Bool {
        guard let handshake = await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake else {
            return false
        }
        return expectedContent == nil || handshake.supportsExpectedContentWrite
    }
}
