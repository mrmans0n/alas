import Darwin
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// One hook handler as Codex's app-server `hooks/list` reports it.
public struct CodexListedHook: Equatable, Sendable {
    public let key: String
    public let command: String?
    public let sourcePath: String
    public let currentHash: String
    public let trustStatus: String

    public init(key: String, command: String?, sourcePath: String, currentHash: String, trustStatus: String) {
        self.key = key
        self.command = command
        self.sourcePath = sourcePath
        self.currentHash = currentHash
        self.trustStatus = trustStatus
    }

    init?(json: [String: Any]) {
        guard let key = json["key"] as? String,
              let sourcePath = json["sourcePath"] as? String,
              let currentHash = json["currentHash"] as? String,
              let trustStatus = json["trustStatus"] as? String
        else { return nil }
        self.init(
            key: key, command: json["command"] as? String, sourcePath: sourcePath,
            currentHash: currentHash, trustStatus: trustStatus)
    }
}

/// Codex skips every user hook it has not trusted, without an error. Trust
/// lives in `config.toml` as `[hooks.state."<key>"] trusted_hash = …`, where
/// the hash is Codex's own digest of the normalized hook. Rather than
/// recompute it, Alas asks the app-server for the current hashes and writes
/// them back the way the TUI's `/hooks` review does.
public enum CodexHookTrust {
    /// Alas's own hooks that Codex does not trust yet. Only handlers that
    /// live in `hooksURL` and carry one of `commands` qualify, so a project
    /// `.codex/hooks.json` that copies the ownership sentinel is never
    /// trusted on the user's behalf.
    public static func untrustedManagedHooks(
        in hooks: [CodexListedHook], hooksURL: URL, commands: Set<String>
    ) -> [CodexListedHook] {
        managedHooks(in: hooks, hooksURL: hooksURL, commands: commands).filter { $0.trustStatus != "trusted" }
    }

    static func managedHooks(
        in hooks: [CodexListedHook], hooksURL: URL, commands: Set<String>
    ) -> [CodexListedHook] {
        let hooksPath = canonicalPath(hooksURL)
        return hooks.filter { hook in
            guard let command = hook.command, commands.contains(command) else { return false }
            return canonicalPath(URL(fileURLWithPath: hook.sourcePath)) == hooksPath
        }
    }

    /// The path Codex uses in hook keys: symlinks resolved by the kernel.
    /// Foundation's `resolvingSymlinksInPath` is not equivalent, since it
    /// maps `/private/tmp` back to `/tmp`.
    public static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Trusts the installed Alas hooks through `codex app-server`, then
    /// re-lists to confirm Codex now runs every one of them.
    public static func trustViaAppServer(hooksURL: URL, commands: Set<String>) async throws {
        let transport = JSONRPCStdioTransport(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "exec codex app-server"],
            environment: nil,
            framing: .newline
        )
        try transport.start()
        defer { transport.terminate() }
        let session = AppServerSession(transport: transport)
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path

        try await withAppServerTimeout(30) {
            _ = try await session.request("initialize", ["clientInfo": ["name": "alas", "version": "1"]])
            try session.notify("initialized")
            let pending = untrustedManagedHooks(
                in: try await session.listHooks(cwd: cwd), hooksURL: hooksURL, commands: commands)
            if !pending.isEmpty {
                let state = Dictionary(uniqueKeysWithValues: pending.map { ($0.key, ["trusted_hash": $0.currentHash]) })
                _ = try await session.request("config/batchWrite", [
                    "edits": [["keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"]],
                    "reloadUserConfig": true,
                ])
            }
            let managed = managedHooks(
                in: try await session.listHooks(cwd: cwd), hooksURL: hooksURL, commands: commands)
            let trusted = Set(managed.filter { $0.trustStatus == "trusted" }.compactMap(\.command))
            guard trusted == commands else {
                throw CodexInstallerError.trustHooksFailed(
                    "Codex did not report every Alas hook as trusted.")
            }
        }
    }
}

/// Sequential request/response over one app-server process. Notifications
/// and stderr are dropped; Alas only needs the replies to its own requests.
private final class AppServerSession: @unchecked Sendable {
    private let transport: JSONRPCStdioTransport
    private var iterator: AsyncStream<JSONRPCStdioTransport.Incoming>.AsyncIterator
    private var nextID = 1

    package init(transport: JSONRPCStdioTransport) {
        self.transport = transport
        self.iterator = transport.incoming.makeAsyncIterator()
    }

    func notify(_ method: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        try transport.send(data)
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> Any {
        let id = nextID
        nextID += 1
        let data = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        try transport.send(data)
        while let incoming = await iterator.next() {
            guard case .frame(let frame, let onConsumed) = incoming else {
                if case .exited(let status) = incoming {
                    throw CodexInstallerError.trustHooksFailed("codex app-server exited with status \(status).")
                }
                continue
            }
            onConsumed?()
            guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  json["id"] as? Int == id
            else { continue }
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                throw CodexInstallerError.trustHooksFailed("\(method) failed: \(message)")
            }
            return json["result"] ?? NSNull()
        }
        throw CodexInstallerError.trustHooksFailed("codex app-server closed before answering \(method).")
    }

    func listHooks(cwd: String) async throws -> [CodexListedHook] {
        let result = try await request("hooks/list", ["cwds": [cwd]])
        let entries = (result as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap(CodexListedHook.init(json:)) }
    }
}

private func withAppServerTimeout(
    _ seconds: TimeInterval,
    _ operation: @Sendable @escaping () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CodexInstallerError.trustHooksFailed("codex app-server did not answer in time.")
        }
        _ = try await group.next()
        group.cancelAll()
    }
}
