import CryptoKit
import Foundation

// MARK: - Helper messages (`pproc/*`)

struct RemotePluginProcSpawnParams: Encodable, Sendable {
    let procId: String
    let lease: String
    /// Exactly the argv to run; the helper starts it without a shell.
    let argv: [String]
    /// The worktree's real path on the host.
    let cwd: String
    let longRunning: Bool
    let stdinBase64: String?
    /// stdout and stderr together, kept by the helper.
    let outputLimit: Int
    let leaseMs: Int
    let timeoutMs: Int?
}

struct RemotePluginProcOwnedParams: Encodable, Sendable {
    let procId: String
    let lease: String
    var offset: UInt64?
    var leaseMs: Int?
}

struct RemotePluginProcOK: Decodable {}

/// A run of one stream's output, at a logical offset over both streams.
struct RemotePluginProcChunk: Codable, Equatable, Sendable {
    /// Set on notifications only.
    var procId: String?
    let seq: UInt64
    let stream: String
    let offset: UInt64
    let dataBase64: String
}

struct RemotePluginProcAttachResult: Decodable, Sendable {
    let running: Bool
    let truncated: Bool
    let chunks: [RemotePluginProcChunk]
    let exit: Int32?
}

struct RemotePluginProcExit: Codable, Equatable, Sendable {
    let procId: String
    let exit: Int32
    let timedOut: Bool
    let truncated: Bool
}

enum RemotePluginProcEvent: Sendable {
    case output(RemotePluginProcChunk)
    case exit(RemotePluginProcExit)
}

// MARK: - The process

/// A plugin process on an SSH host, run by the remote helper, which owns its cleanup: Alas only asks it to stop.
/// Alas renews the process's lease while it runs, so the helper stops it when Alas is gone.
final class RemotePluginProcess: PluginProcessHandle, @unchecked Sendable {
    static let leaseMs = 60_000
    static let renewInterval: Duration = .seconds(20)

    var events: AsyncStream<PluginProcessEvent> { output.events }
    private let output: PluginProcessOutput
    private let host: String
    private let procId: String
    private let lease: String
    private let lock = NSLock()
    /// Set once the helper started the process.
    private var client: RemoteHelperClient?
    private var stopRequested = false

    init(host: String, procId: String, lease: String, keep: PluginProcessOutput.Keep, limit: Int) {
        self.host = host
        self.procId = procId
        self.lease = lease
        output = PluginProcessOutput(keep: keep, limit: limit)
    }

    /// An id no other plugin, project, instance or run shares, and that names none of them.
    static func procId(plugin: String, project: String, lease: String, run: String) -> String {
        let digest = SHA256.hash(data: Data([plugin, project, lease, run].joined(separator: "\u{0}").utf8))
        return "pp-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Starts the process and follows it. Throws why the host refused it; afterwards, everything comes as events.
    func start(argv: [String], cwd: String, stdin: Data?, longRunning: Bool, limit: Int, timeout: Duration?) async throws {
        let client: RemoteHelperClient
        do {
            // The probe tells a host that is down from one without the helper, and is cached per host.
            guard let capabilities = await RemoteHostCapabilityStore.shared.capabilities(for: host) else {
                throw PluginRemoteFileProblem.unreachable
            }
            guard capabilities.helperHandshake != nil else { throw PluginRemoteFileProblem.helperMissing }
            client = await RemoteHelperClientPool.shared.client(for: host)
            let params = RemotePluginProcSpawnParams(
                procId: procId, lease: lease, argv: argv, cwd: cwd, longRunning: longRunning,
                stdinBase64: stdin?.base64EncodedString(),
                // The output keeps up to `limit` of each stream, so the helper keeps both together.
                outputLimit: limit * 2, leaseMs: Self.leaseMs,
                timeoutMs: timeout.map { Int($0.components.seconds) * 1000 })
            do {
                try await Self.spawnRetrying { try await client.spawnPluginProc(params) }
            } catch {
                // It may have started all the same: stop it if the connection is back, or its lease lapses.
                if Self.isConnectionFailure(error) {
                    Task { [procId, lease] in try? await client.killPluginProc(procId: procId, lease: lease) }
                }
                throw error
            }
        } catch {
            // The helper's own refusals (a macOS host, a kernel without pidfds, a command it can't find) pass through.
            throw PluginProcessError.refused(
                PluginFiles.remoteFailure(error, host: host, need: "run commands there").message)
        }
        let stop = lock.withLock { () -> Bool in
            self.client = client
            return stopRequested
        }
        if stop { terminate() }
        Task { await follow(client) }
    }

    /// Spawns again, under the same id, when the connection drops: the helper may have started the process before
    /// its answer was lost, and a repeated spawn of the same id and lease only reports it.
    static func spawnRetrying(
        attempts: Int = 3, pause: Duration = .seconds(1), _ spawn: @Sendable () async throws -> Void
    ) async throws {
        for attempt in 1... {
            do {
                return try await spawn()
            } catch where attempt < attempts && isConnectionFailure(error) {
                try? await Task.sleep(for: pause)
            }
        }
    }

    static func isConnectionFailure(_ error: Error) -> Bool {
        switch error as? RemoteHelperClientError {
        case .notRunning, .unavailable: true
        default: false
        }
    }

    /// Reads the output until the exit, attaching again from where it got to when the connection drops.
    private func follow(_ client: RemoteHelperClient) async {
        let renew = Task { [client, procId, lease] in
            while (try? await Task.sleep(for: Self.renewInterval)) != nil {
                try? await client.renewPluginProc(procId: procId, lease: lease, leaseMs: Self.leaseMs)
            }
        }
        defer { renew.cancel() }
        var next: UInt64 = 0
        var failures = 0
        while true {
            let attached: (RemotePluginProcAttachResult, AsyncStream<RemotePluginProcEvent>)
            do {
                attached = try await client.attachPluginProc(procId: procId, lease: lease, offset: next)
                failures = 0
            } catch {
                // The helper answered, so the process is gone or not ours: nothing to wait for.
                // ponytail: a dropped connection is retried for about two minutes; the helper's lease stops the
                // process once Alas gives up.
                failures += 1
                if case .jsonrpc? = error as? RemoteHelperClientError { return finish(exit: -1, truncated: false) }
                if failures > 60 { return finish(exit: -1, truncated: false) }
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            let (result, stream) = attached
            for chunk in result.chunks { append(chunk, next: &next) }
            if let exit = result.exit { return finish(exit: exit, truncated: result.truncated) }
            for await event in stream {
                switch event {
                case .output(let chunk): append(chunk, next: &next)
                case .exit(let exit): return finish(exit: exit.exit, truncated: exit.truncated)
                }
            }
        }
    }

    private func append(_ chunk: RemotePluginProcChunk, next: inout UInt64) {
        guard let data = Data(base64Encoded: chunk.dataBase64),
              let unseen = Self.unseen(data, at: chunk.offset, after: next) else { return }
        output.append(unseen, stream: chunk.stream == "stderr" ? 1 : 0)
        next = chunk.offset + UInt64(data.count)
    }

    /// The part of a chunk at `offset` that follows `next`, the end of what was read: a replay after a reconnect
    /// can repeat output, and a chunk can grow after part of it was read.
    static func unseen(_ data: Data, at offset: UInt64, after next: UInt64) -> Data? {
        let end = offset + UInt64(data.count)
        guard end > next else { return nil }
        return data.suffix(Int(end - max(offset, next)))
    }

    private func finish(exit: Int32, truncated: Bool) {
        if truncated { output.markTruncated() }
        output.finish(exit: exit)
        let client = lock.withLock { self.client }
        Task { [procId, lease] in try? await client?.releasePluginProc(procId: procId, lease: lease) }
    }

    /// The helper sends `SIGTERM` and, after its grace, `SIGKILL` to the process and everything it started.
    func terminate() {
        let client = lock.withLock { () -> RemoteHelperClient? in
            stopRequested = true
            return self.client
        }
        guard let client else { return }
        Task { [procId, lease] in try? await client.killPluginProc(procId: procId, lease: lease) }
    }

    func kill() { terminate() }
}
